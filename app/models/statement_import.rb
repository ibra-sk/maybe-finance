# Imports an OFX/QFX statement downloaded from a bank (TD, RBC, CIBC, ...) into one account.
#
# Unlike a CSV import there is no column configuration: the file is parsed into rows on
# upload, transactions already in the account are skipped, and on publish the account
# balance is set from the statement's closing (ledger) balance.
class StatementImport < TransactionImport
  attr_reader :skipped_count

  def statement
    @statement ||= Ofx.new(raw_file_str)
  end

  # Raises StatementImport::Ofx::ParseError for files that can't be read
  def upload_statement!(raw, account: nil)
    raw = Ofx.to_utf8(raw)
    @statement = Ofx.new(raw)

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

      existing = existing_transaction_keys
      @skipped_count = 0

      new_rows = statement.transactions.filter_map do |txn|
        key = [ txn.date, -txn.amount, txn.name ]

        if existing[key].to_i.positive?
          existing[key] -= 1
          @skipped_count += 1
          next
        end

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
    # matched by (date, amount, name) and skipped. Counts are kept so two identical purchases on
    # the same day are both imported when only one exists. FITIDs aren't used because some
    # banks regenerate them on every download.
    def existing_transaction_keys
      return {} if account.nil? || statement.transactions.empty?

      dates = statement.transactions.map(&:date)

      account.entries
             .where(entryable_type: "Transaction", date: dates.min..dates.max)
             .pluck(:date, :amount, :name)
             .map { |date, amount, name| [ date, amount.to_d, name ] }
             .tally
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
      [ statement.bank, statement.account_id ]
    end
end
