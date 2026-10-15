# Parses the text of a PDF bank statement (see StatementImport::PdfText) for the layouts
# MacroFinance knows:
#   - TD chequing and savings "Statement of Account"
#   - TD credit cards
#   - Canadian Tire (CTFS) Triangle Mastercard
#
# Every statement must reconcile: the opening balance plus its transactions (and, for TD bank
# accounts, every printed running balance) has to match to the cent, or it is rejected. That
# catches misread rows and bank layout changes instead of importing wrong numbers.
#
# Exposes the same interface as StatementImport::Ofx.
class StatementImport::Pdf
  Transaction = StatementImport::Ofx::Transaction

  # PDF text is stored with the original file name on its first line, because TD bank
  # statements only show the account type and number in the file name.
  FILE_NAME_LINE = /\A# file: (.*)\n/

  NUMBER = /\d{1,3}(?:,\d{3})*\.\d{2}/
  # TD marks an overdrawn (negative) balance with a trailing "OD", with or without a space
  BALANCE = /#{NUMBER}(?:\s*OD)?/
  MONTHS = Date::ABBR_MONTHNAMES.compact.each_with_index.to_h { |name, i| [ name.upcase, i + 1 ] }

  attr_reader :bank, :account_id, :account_type, :currency, :balance, :balance_date, :transactions

  def self.with_file_name(text, file_name)
    "# file: #{file_name.to_s.tr("\n", " ")}\n#{text}"
  end

  def initialize(stored_text)
    @file_name = stored_text[FILE_NAME_LINE, 1].to_s
    @text = stored_text.sub(FILE_NAME_LINE, "")
    @currency = "CAD"

    if @text.include?("Statement of Account") && @text.match?(/Withdrawals\s+Deposits\s+Date\s+Balance/)
      parse_td_bank_account
    elsif @text.match?(/STATEMENT PERIOD:/) && @text.match?(/^\s*TD\b.*\bCARD\s*$/)
      parse_credit_card(bank: "TD", product: @text[/^\s*(TD\b.*\bCARD)\s*$/, 1].strip.titleize.sub("Td ", "TD "))
    elsif @text.match?(/For the period:/) && @text.match?(/triangle/i)
      parse_credit_card(bank: "Canadian Tire", product: "Triangle Mastercard")
    else
      raise StatementImport::ParseError, "Unsupported PDF statement. Supported: TD chequing/savings, TD credit cards and Triangle Mastercard."
    end

    raise StatementImport::ParseError, "No transactions or balance found in the statement" if transactions.empty? && balance.nil?
  end

  def credit_card?
    account_type == "CREDITCARD"
  end

  # The kind of account without its number, for matching statements that lack one
  def account_kind
    @kind || @product
  end

  def account_label
    [ @product, account_id && "••#{account_id.last(4)}" ].compact.join(" ")
  end

  private
    # TD "Statement of Account": Description | Withdrawals | Deposits | Date | Balance, where a
    # balance is printed after the last transaction of each day.
    def parse_td_bank_account
      @bank = "TD"
      # TD's download file name has the account type and number. The (abbreviated) account type
      # printed on the statement, e.g. "UNLIMITED" or "EVRY DAY SAV", identifies the account when
      # the file was renamed, e.g. after unlocking it.
      type_name = td_account_type_name
      @account_type = if "#{type_name} #{@file_name}".match?(/SAV/i)
        "SAVINGS"
      elsif type_name || @file_name.match?(/CHEQ|CHECK/i)
        "CHECKING" # chequing accounts and TD's bank plans
      end
      @product = "TD #{{ "SAVINGS" => "Savings", "CHECKING" => "Chequing" }.fetch(@account_type, "Account")}"
      @kind = "TD #{type_name.squish.upcase}" if type_name
      @account_id = @file_name[/_(\d{4}-\d{7})_/, 1]

      period = @text.match(/([A-Z]{3}) (\d{1,2})\/(\d{2}) - ([A-Z]{3}) (\d{1,2})\/(\d{2})/) or
        raise StatementImport::ParseError, "Couldn't find the statement period"
      period_end = Date.new(2000 + period[6].to_i, month(period[4]), period[5].to_i)

      opening = closing = running = nil
      split_column = nil
      @transactions = []

      @text.each_line do |line|
        if (header = line.match(/(Withdrawals)\s+(Deposits)/))
          # Amounts are right-aligned under their headings
          split_column = (header.end(1) + header.end(2)) / 2
        elsif (m = line.match(/^\s*STARTING BALANCE\s+[A-Z]{3}\d{2}\s+(?<balance>#{BALANCE})\s*$/))
          opening ||= running = td_balance(m[:balance])
        elsif (m = line.match(/^\s*CLOSING BALANCE\s+[A-Z]{3}\d{2}\s+(?<balance>#{BALANCE})\s*$/))
          closing = td_balance(m[:balance])
        elsif split_column && (m = line.match(/^\s?(?<description>\S.*?)\s{2,}(?<amount>#{NUMBER})\s+(?<date>[A-Z]{3}\d{2})(?:\s+(?<balance>#{BALANCE}))?\s*$/))
          raise StatementImport::ParseError, "Transactions start before the starting balance" if running.nil?

          withdrawal = m.end(:amount) < split_column
          value = withdrawal ? -amount(m[:amount]) : amount(m[:amount])
          running += value

          @transactions << Transaction.new(
            date: date_in_period(m[:date][0, 3], m[:date][3, 2].to_i, period_end),
            amount: value,
            name: m[:description].squeeze(" ").strip,
            memo: nil
          )

          if m[:balance] && td_balance(m[:balance]) != running
            raise StatementImport::ParseError, "Running balance on #{m[:date]} doesn't match the transactions (off by #{(td_balance(m[:balance]) - running).abs})"
          end
        end
      end

      raise StatementImport::ParseError, "Couldn't find the starting balance" if opening.nil?

      @balance = closing || running
      @balance_date = period_end
      reconcile!(opening, @balance)
    end

    # Credit card statements: transaction date, posting date, description, amount. Charges are
    # positive and payments/credits negative; balances are amounts owed.
    def parse_credit_card(bank:, product:)
      @bank = bank
      @product = product
      @account_type = "CREDITCARD"
      @account_id = @text[/Card #\s*\d{4}[\dX ]*?(\d{4})\b/, 1] || @file_name[/CARD_(\d{4})/, 1]

      period_end = @text[/(?:STATEMENT PERIOD|For the period):\s*[A-Za-z]+ \d{1,2}, \d{4} to ([A-Za-z]+ \d{1,2}, \d{4})/, 1] or
        raise StatementImport::ParseError, "Couldn't find the statement period"
      period_end = Date.parse(period_end)

      opening = @text[/(?:PREVIOUS STATEMENT BALANCE|Balance from your \S+ statement)\s+(-?\$?#{NUMBER})/i, 1] or
        raise StatementImport::ParseError, "Couldn't find the previous balance"
      closing = @text[/(?:TOTAL NEW BALANCE|Your New Balance)\s+(-?\$?#{NUMBER})/i, 1] or
        raise StatementImport::ParseError, "Couldn't find the new balance"

      # Lines start with the transaction date and posting date; anything after the amount (side
      # panels) is ignored. The posting date is used, as in OFX downloads, so the same purchase
      # matches across PDF and QFX imports.
      transaction_line = /^\s{0,6}[A-Za-z]{3} \d{1,2}\s+(?<month>[A-Za-z]{3}) (?<day>\d{1,2})\s*(?<description>.*?)\s{2,}(?<amount>-?\$?#{NUMBER})(?=\s|$)/

      # Triangle statements end with "Details of your Canadian Tire store purchases", which
      # itemizes purchases already listed above, so reading stops there
      transactions_text = @text.split(/^\s*Details of your Canadian Tire .*purchases\s*$/i).first

      @transactions = transactions_text.each_line.filter_map do |line|
        m = line.match(transaction_line)
        next unless m && MONTHS.key?(m[:month].upcase)

        Transaction.new(
          date: date_in_period(m[:month], m[:day].to_i, period_end),
          amount: -amount(m[:amount]), # money owed going up is money out, as in OFX
          name: m[:description].squeeze(" ").strip,
          memo: nil
        )
      end

      # Balances are kept the way OFX reports credit cards: negative when money is owed
      @balance = -amount(closing)
      @balance_date = period_end
      reconcile!(-amount(opening), @balance)
    end

    def reconcile!(opening, closing)
      difference = opening + transactions.sum(&:amount) - closing
      return if difference.zero?

      raise StatementImport::ParseError,
            "The statement doesn't add up: opening balance plus #{transactions.size} transactions is off from the closing balance by #{difference.abs}"
    end

    # Statements show dates without a year; they all fall on or before the period end
    def date_in_period(month_name, day, period_end)
      date = Date.new(period_end.year, month(month_name), day)
      date > period_end + 7.days ? date.prev_year : date
    end

    def month(name)
      MONTHS.fetch(name[0, 3].upcase) { raise StatementImport::ParseError, "Unknown month #{name}" }
    end

    # The value printed under the "Account Type" heading, if it's readable text
    def td_account_type_name
      lines = @text.lines
      header_index = lines.index { |line| line.include?("Account Type") } or return nil
      column = lines[header_index].index("Account Type")

      lines[header_index + 1, 4].each do |line|
        start = line.index(/\S/, [ column - 12, 0 ].max)
        next if start.nil? || start > column + 12

        value = line[start..].split(/\s{2,}/).first.strip
        return value if value.match?(/\A[A-Za-z][A-Za-z .&'-]*\z/)
      end

      nil
    end

    def td_balance(text)
      text.end_with?("OD") ? -amount(text.delete_suffix("OD").strip) : amount(text)
    end

    def amount(text)
      BigDecimal(text.delete("$,"))
    end
end
