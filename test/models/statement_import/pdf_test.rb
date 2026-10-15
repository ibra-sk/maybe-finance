require "test_helper"

# Fixtures are synthetic statements laid out like `pdftotext -layout` output of real ones
class StatementImport::PdfTest < ActiveSupport::TestCase
  test "parses a TD chequing statement across pages" do
    pdf = parse("td_chequing.txt", file_name: "TD_UNLIMITED_CHEQUING_ACCOUNT_1234-5678901_Apr_30-May_29_2026.pdf")

    assert_equal "TD Chequing ••8901", pdf.account_label
    assert_equal "CHECKING", pdf.account_type
    assert_equal BigDecimal("1384.05"), pdf.balance
    assert_equal Date.new(2026, 5, 29), pdf.balance_date
    assert_equal [ -4.50, -95.50, 1000.00, -15.95 ].map { BigDecimal(_1.to_s) }, pdf.transactions.map(&:amount)
    assert_equal [ "COFFEE SHOP #12 _F", Date.new(2026, 5, 2) ], [ pdf.transactions.first.name, pdf.transactions.first.date ]
  end

  test "identifies a renamed TD statement from the account type it prints" do
    pdf = parse("td_chequing.txt", file_name: "statement-unlocked.pdf")

    assert_equal "TD Chequing", pdf.account_label
    assert_equal "CHECKING", pdf.account_type
    assert_equal "TD UNLIMITED CHEQUING", pdf.account_kind
  end

  test "reads overdrawn (OD) TD balances as negative" do
    text = fixture("td_chequing.txt")
             .sub(/500\.00$/, "500.00 OD")      # starting balance
             .sub(/ 400\.00$/, " 600.00 OD")    # after two withdrawals
             .gsub(/1,400\.00$/, "400.00")      # after the deposit, and balance forward
             .gsub(/1,384\.05$/, "384.05")      # after the fee, and closing balance

    pdf = StatementImport::Pdf.new(StatementImport::Pdf.with_file_name(text, "x.pdf"))

    assert_equal BigDecimal("384.05"), pdf.balance
    assert_equal 4, pdf.transactions.size
  end

  test "rejects a TD statement whose running balance doesn't match" do
    text = fixture("td_chequing.txt").sub("1,400.00\n", "1,500.00\n")

    error = assert_raises(StatementImport::ParseError) { StatementImport::Pdf.new(StatementImport::Pdf.with_file_name(text, "x.pdf")) }
    assert_match "Running balance on MAY15", error.message
  end

  test "parses a TD credit card statement spanning the new year" do
    pdf = parse("td_visa.txt", file_name: "TD_REWARDS_VISA__CARD_0206_Jan_19-2026.pdf")

    assert pdf.credit_card?
    assert_equal "TD Rewards Card ••0206", pdf.account_label
    assert_equal BigDecimal("-174.25"), pdf.balance
    # Posting dates, like OFX downloads
    assert_equal [ Date.new(2025, 12, 29), Date.new(2026, 1, 3), Date.new(2026, 1, 19) ], pdf.transactions.map(&:date)
    assert_equal [ -45.25, 100.00, -29.00 ].map { BigDecimal(_1.to_s) }, pdf.transactions.map(&:amount)
  end

  # The fixture also itemizes the hardware store purchase in a "Details of your Canadian Tire
  # store purchases" section, which must not be counted a second time
  test "parses a Triangle Mastercard statement, ignoring side panels, wrapped lines and itemized purchases" do
    pdf = parse("triangle.txt", file_name: "statement.pdf")

    assert_equal "Triangle Mastercard ••4321", pdf.account_label
    assert_equal BigDecimal("-120.40"), pdf.balance
    assert_equal [ "CTFS.COM/PAYMENTS TORONTO ON", "HARDWARE STORE ON", "TRIANGLE REWARDS (EARN", "INTEREST CHARGES" ], pdf.transactions.map(&:name)
  end

  test "rejects a credit card statement that doesn't add up" do
    text = fixture("triangle.txt").sub("$120.40", "$121.40")

    error = assert_raises(StatementImport::ParseError) { StatementImport::Pdf.new(StatementImport::Pdf.with_file_name(text, "x.pdf")) }
    assert_match "off from the closing balance by 1.0", error.message
  end

  test "rejects unknown statement layouts" do
    assert_raises(StatementImport::ParseError) { StatementImport::Pdf.new(StatementImport::Pdf.with_file_name("Some other bank\n", "x.pdf")) }
  end

  private
    def fixture(name)
      file_fixture("statements/#{name}").read
    end

    def parse(name, file_name:)
      StatementImport::Pdf.new(StatementImport::Pdf.with_file_name(fixture(name), file_name))
    end
end
