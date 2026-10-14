require "test_helper"

class StatementImport::OfxTest < ActiveSupport::TestCase
  test "parses an SGML (OFX 1.x) chequing statement" do
    ofx = parse("rbc_chequing.qfx")

    assert_equal "RBC Chequing ••1234", ofx.account_label
    assert_equal "CAD", ofx.currency
    assert_equal BigDecimal("3140.30"), ofx.balance
    assert_equal Date.new(2024, 1, 31), ofx.balance_date
    assert_equal 3, ofx.transactions.size

    first = ofx.transactions.first
    assert_equal Date.new(2024, 1, 5), first.date
    assert_equal BigDecimal("-4.85"), first.amount
    assert_equal "TIM HORTONS #1234", first.name
    assert_equal "Interac purchase", first.memo
  end

  test "parses an XML (OFX 2.x) statement with comma decimals and a blank name" do
    ofx = parse("td_savings.ofx")

    assert_equal "TD Savings ••9012", ofx.account_label
    assert_equal BigDecimal("12.34"), ofx.transactions.first.amount

    transfer = ofx.transactions.last
    assert_equal "TFR-TO 1234567", transfer.name
    assert_nil transfer.memo
  end

  test "parses a credit card statement" do
    ofx = parse("cibc_visa.qfx")

    assert ofx.credit_card?
    assert_equal "CIBC Credit Card ••9876", ofx.account_label
    assert_equal BigDecimal("-523.10"), ofx.balance
  end

  test "rejects files that aren't a single-account OFX statement" do
    assert_raises(StatementImport::Ofx::ParseError) { StatementImport::Ofx.new("date,amount\n2024-01-01,5") }

    statement = file_fixture("statements/rbc_chequing.qfx").read[/<STMTRS>.*<\/STMTRS>/m]
    two_accounts = "<OFX>#{statement}#{statement}</OFX>"
    error = assert_raises(StatementImport::Ofx::ParseError) { StatementImport::Ofx.new(two_accounts) }
    assert_match "2 accounts", error.message
  end

  private
    def parse(name)
      StatementImport::Ofx.new(file_fixture("statements/#{name}").read)
    end
end
