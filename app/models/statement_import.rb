# Imports a bank statement into one account: an OFX/QFX download (most banks) or a PDF
# statement (TD and Triangle Mastercard layouts, see StatementImport::Pdf).
#
# Unlike a CSV import there is no column configuration: the file is parsed into rows on
# upload, transactions already in the account are skipped, and on publish the account
# balance is set from the statement's closing (ledger) balance.
class StatementImport < TransactionImport
  ParseError = Class.new(StandardError)

  # Raised when the same bank account already has an uploaded statement that isn't published
  # yet. Publishing both would duplicate its transactions (or create the account twice).
  class PendingImportError < ParseError
    attr_reader :pending_import

    def initialize(pending_import)
      @pending_import = pending_import
      super("#{pending_import.statement.account_label} already has a statement import waiting to be published. Publish or delete it first.")
    end
  end

  attr_reader :skipped_count

  def statement
    @statement ||= raw_file_str.match?(Pdf::FILE_NAME_LINE) ? Pdf.new(raw_file_str) : Ofx.new(raw_file_str)
  end

  # Accepts an OFX/QFX file or a PDF statement. Raises StatementImport::ParseError for files
  # that can't be read. The file name helps identify the account for PDF statements.
  def upload_statement!(raw, account: nil, file_name: nil)
    if raw.to_s.start_with?("%PDF")
      raw = Pdf.with_file_name(PdfText.extract(raw), file_name)
      @statement = Pdf.new(raw)
    else
      raw = Ofx.to_utf8(raw)
      @statement = Ofx.new(raw)
    end

    pending_import = pending_import_for_same_account(account)
    raise PendingImportError.new(pending_import) if pending_import

    assign_attributes(
      raw_file_str: raw,
      account: account || matching_account,
      date_format: "%Y-%m-%d",
      signage_convention: "inflows_positive", # OFX amounts are positive for money in
      amount_type_strategy: "signed_amount"
    )
    save!

    generate_rows_from_statement
  end

  def statement_transaction_count
    statement.transactions.size
  end

  def configurable?
    false
  end

  def dry_run
    { transactions: rows.count, accounts: account ? 0 : 1 }
  end

  # Categories come from rules after import, so no category/tag mapping step
  def column_keys
    %i[date amount name currency notes]
  end

  def mapping_steps
    []
  end

  def import!
    transaction do
      new_account = account.nil?
      update!(account: create_statement_account!) if new_account

      super

      new_account ? set_opening_balance_from_statement! : reconcile_statement_balance!
    end
  end

  private
    def generate_rows_from_statement
      rows.destroy_all

      new_transactions = new_statement_transactions
      @skipped_count = statement.transactions.size - new_transactions.size

      new_rows = new_transactions.map do |txn|
        {
          date: txn.date.iso8601,
          amount: txn.amount.to_s,
          name: txn.name || default_row_name,
          notes: txn.memo,
          currency: statement_currency
        }
      end

      rows.insert_all!(new_rows) if new_rows.any?
      rows.reset
    end

    # Overlapping statement downloads are the norm, so transactions already in the account are
    # skipped. A transaction matches an existing one with the same date and amount; the name
    # only breaks ties, so transactions renamed after import (by you or a rule) and descriptions
    # that differ between QFX and PDF still match. Each existing transaction matches at most
    # once, so two identical purchases on the same day are both kept when only one exists.
    # FITIDs aren't used because some banks regenerate them on every download.
    def new_statement_transactions
      return statement.transactions if account.nil? || statement.transactions.empty?

      dates = statement.transactions.map(&:date)
      existing_names = account.entries
                              .where(entryable_type: "Transaction", date: dates.min..dates.max)
                              .pluck(:date, :amount, :name)
                              .group_by { |date, amount, _| [ date, amount.to_d ] }
                              .transform_values { |matches| matches.map(&:last) }

      # Same date, amount and name first, so ties go to the right transaction...
      unmatched = statement.transactions.reject do |txn|
        names = existing_names[[ txn.date, -txn.amount ]]
        index = names&.index(txn.name)
        names.delete_at(index) if index
        index.present?
      end

      # ...then same date and amount, whatever the name
      unmatched.reject do |txn|
        names = existing_names[[ txn.date, -txn.amount ]]
        next false if names.blank?

        names.shift
        true
      end
    end

    # An earlier upload for the same bank account (or the chosen account) that hasn't been
    # published yet
    def pending_import_for_same_account(chosen_account)
      family.imports
            .where(type: "StatementImport", status: %i[pending importing])
            .where.not(id: id)
            .order(:created_at)
            .select { |import| import.rows.exists? }
            .find do |import|
              (chosen_account && import.account_id == chosen_account.id) ||
                (import.statement_key == statement_key rescue false)
            end
    end

    # Reuses the account a previous import of the same bank account went into
    def matching_account
      family.imports
            .where(type: "StatementImport", status: :complete)
            .where.not(id: id)
            .where.not(account_id: nil)
            .order(created_at: :desc)
            .find { |import| import.statement_key == statement_key rescue false }
            &.account
    end

    def create_statement_account!
      family.accounts.create!(
        name: statement.account_label,
        balance: 0,
        currency: statement_currency,
        import: self,
        subtype: depository_subtype,
        accountable: statement.credit_card? ? CreditCard.new : Depository.new
      )
    end

    # The opening balance that makes the statement's transactions end at its closing balance
    def set_opening_balance_from_statement!
      return if statement.balance.nil?

      flows = statement.transactions.select { |t| t.date <= statement.balance_date }.sum(&:amount)
      first_date = statement.transactions.map(&:date).min || statement.balance_date

      result = account.set_opening_anchor_balance(
        balance: account_balance(statement.balance - flows),
        date: first_date - 1.day
      )
      raise result.error if result.error
    end

    def reconcile_statement_balance!
      return if statement.balance.nil?

      valuation = account.entries.valuations.find_by(date: statement.balance_date)

      if valuation
        valuation.update!(amount: account_balance(statement.balance))
      else
        account.entries.create!(
          date: statement.balance_date,
          name: Valuation.build_reconciliation_name(account.accountable_type),
          amount: account_balance(statement.balance),
          currency: account.currency,
          import: self,
          entryable: Valuation.new(kind: "reconciliation")
        )
      end
    end

    # OFX credit card balances are negative when money is owed; liabilities here are positive
    def account_balance(ofx_balance)
      account.accountable.classification == "liability" ? -ofx_balance : ofx_balance
    end

    def statement_currency
      statement.currency || account&.currency || family.currency
    end

    def depository_subtype
      { "CHECKING" => "checking", "SAVINGS" => "savings" }[statement.account_type]
    end

  protected
    def statement_key
      [ statement.bank, statement.account_id.presence || statement.account_label ]
    end
end
