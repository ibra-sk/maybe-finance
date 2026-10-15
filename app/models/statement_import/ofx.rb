# Parses a single-account OFX/QFX bank or credit card statement (the "Quicken" / "Microsoft
# Money" download offered by TD, RBC, CIBC and most other banks).
#
# Handles both OFX 1.x (SGML, leaf tags left unclosed) and OFX 2.x (XML) by reading each
# leaf value up to the next tag or line break.
class StatementImport::Ofx
  ParseError = StatementImport::ParseError

  Transaction = Data.define(:date, :amount, :name, :memo)

  STATEMENT = %r{<(?:CC)?STMTRS>.*?</(?:CC)?STMTRS>}m

  attr_reader :bank, :account_id, :account_type, :currency, :balance, :balance_date, :transactions

  # Bank files are often Windows-1252 rather than UTF-8
  def self.to_utf8(str)
    utf8 = str.to_s.dup.force_encoding(Encoding::UTF_8)
    utf8.valid_encoding? ? utf8 : str.to_s.dup.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8)
  end

  def initialize(raw)
    body = self.class.to_utf8(raw)[/<OFX>.*/m]
    raise ParseError, "This doesn't look like an OFX/QFX file" if body.nil?

    statements = body.scan(STATEMENT).size
    raise ParseError, "No account statement found in the file" if statements.zero?
    raise ParseError, "The file has #{statements} accounts. Download one account at a time." if statements > 1

    statement = body[STATEMENT]
    ledger = statement[%r{<LEDGERBAL>.*?</LEDGERBAL>}m]

    @bank = value(body, "ORG")
    @account_id = value(statement, "ACCTID")
    @account_type = statement.include?("<CCACCTFROM>") ? "CREDITCARD" : value(statement, "ACCTTYPE")
    @currency = value(statement, "CURDEF")
    @balance = amount(value(ledger, "BALAMT")) if ledger
    @balance_date = date(value(ledger, "DTASOF")) if ledger

    @transactions = statement.scan(%r{<STMTTRN>.*?</STMTTRN>}m).map do |trn|
      name = value(trn, "NAME")
      memo = value(trn, "MEMO")

      Transaction.new(
        date: date(value(trn, "DTPOSTED")),
        amount: amount(value(trn, "TRNAMT")),
        name: name || memo,
        memo: (memo if name)
      )
    end

    raise ParseError, "No transactions or balance found in the file" if @transactions.empty? && @balance.nil?
  end

  def credit_card?
    account_type == "CREDITCARD"
  end

  # The kind of account without its number, e.g. "RBC Chequing"
  def account_kind
    account_label.sub(/ ••\w+\z/, "")
  end

  # Shown to the user and used to name accounts created from a statement, e.g. "RBC Chequing ••1234"
  def account_label
    type = { "CHECKING" => "Chequing", "SAVINGS" => "Savings", "CREDITCARD" => "Credit Card", "CREDITLINE" => "Line of Credit" }
             .fetch(account_type, "Account")

    [ short_bank_name, type, account_id && "••#{account_id.gsub(/\W/, '').last(4)}" ].compact.join(" ")
  end

  private
    def value(str, tag)
      CGI.unescapeHTML(str[/<#{tag}>([^<\r\n]*)/, 1].to_s).strip.presence
    end

    # OFX dates are YYYYMMDD with an optional time and timezone suffix
    def date(str)
      Date.strptime(str.to_s[0, 8], "%Y%m%d")
    rescue Date::Error
      raise ParseError, "Invalid date in file: #{str.inspect}"
    end

    # The OFX spec allows a comma as the decimal separator
    def amount(str)
      normalized = str.to_s.include?(".") ? str.to_s.delete(",") : str.to_s.tr(",", ".")
      BigDecimal(normalized)
    rescue ArgumentError
      raise ParseError, "Invalid amount in file: #{str.inspect}"
    end

    def short_bank_name
      case bank.to_s
      when /royal bank|\ARBC/i then "RBC"
      when /\ATD\b|toronto.dominion|canada trust/i then "TD"
      when /CIBC|imperial bank/i then "CIBC"
      else bank
      end
    end
end
