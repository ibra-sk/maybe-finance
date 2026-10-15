require "test_helper"

class StatementImportTest < ActiveSupport::TestCase
  setup do
    @family = Family.create!(name: "Statement family", currency: "CAD")
  end

  test "creates the account and sets its balance from the statement" do
    import = upload("rbc_chequing.qfx")
    import.publish

    assert import.complete?, import.error
    account = import.account
    assert_equal "RBC Chequing ••1234", account.name
    assert_equal "checking", account.subtype
    assert_equal 3, account.entries.transactions.count
    assert_equal BigDecimal("4.85"), account.entries.transactions.order(:date).first.amount # outflow

    assert_equal BigDecimal("3140.30"), materialized_balance(account)
  end

  test "credit card balances owed become a positive liability" do
    import = upload("cibc_visa.qfx")
    import.publish

    assert import.complete?, import.error
    assert_instance_of CreditCard, import.account.accountable
    assert_equal BigDecimal("523.10"), materialized_balance(import.account)
  end

  test "skips transactions already in the account, keeping same-day duplicates" do
    account = create_account
    account.entries.create!(date: Date.new(2024, 1, 5), amount: 4.85, currency: "CAD", name: "TIM HORTONS #1234", entryable: Transaction.new)

    import = upload("rbc_chequing.qfx", account: account)

    assert_equal 1, import.skipped_count
    assert_equal [ "PAYROLL DEPOSIT", "TIM HORTONS #1234" ], import.rows.pluck(:name).sort
  end

  test "a renamed transaction is still recognized as already imported" do
    first = upload("rbc_chequing.qfx")
    first.publish
    first.account.entries.transactions.find_by!(name: "PAYROLL DEPOSIT").update!(name: "Salary")

    second = upload("rbc_chequing.qfx")

    assert_equal first.account, second.account
    assert_empty second.rows
  end

  test "the name breaks ties between transactions with the same date and amount" do
    account = create_account
    account.entries.create!(date: Date.new(2024, 3, 1), amount: 5, currency: "CAD", name: "BAKERY", entryable: Transaction.new)

    import = @family.imports.create!(type: "StatementImport")
    import.upload_statement!(ofx(%w[COFFEE BAKERY].map { |name| [ "20240301", "-5.00", name ] }), account: account)

    assert_equal [ "COFFEE" ], import.rows.pluck(:name)
  end

  test "a second upload for the same account waits until the first is published" do
    first = upload("rbc_chequing.qfx")

    error = assert_raises(StatementImport::PendingImportError) { upload("rbc_chequing.qfx") }
    assert_equal first, error.pending_import
    assert_match "RBC Chequing ••1234 already has a statement import waiting", error.message

    first.publish
    assert_empty upload("rbc_chequing.qfx").rows
  end

  test "reconciles an existing account to the statement balance, and revert removes it" do
    account = create_account
    import = upload("rbc_chequing.qfx", account: account)
    import.publish

    valuation = account.entries.valuations.find_by!(date: Date.new(2024, 1, 31))
    assert_equal BigDecimal("3140.30"), valuation.amount
    assert_equal import, valuation.import

    import.revert
    assert_empty account.entries.reload
  end

  test "imports a PDF statement and matches later ones to the same account" do
    StatementImport::PdfText.stubs(:extract).returns(file_fixture("statements/td_chequing.txt").read)
    file_name = "TD_UNLIMITED_CHEQUING_ACCOUNT_1234-5678901_Apr_30-May_29_2026.pdf"

    first = upload_pdf(file_name)
    first.publish

    assert first.complete?, first.error
    assert_equal "TD Chequing ••8901", first.account.name
    assert_equal "checking", first.account.subtype
    assert_equal BigDecimal("1384.05"), materialized_balance(first.account)

    second = upload_pdf(file_name)
    assert_equal first.account, second.account
    assert_empty second.rows
  end

  test "a renamed copy of a TD PDF goes into the same account as the original download" do
    StatementImport::PdfText.stubs(:extract).returns(file_fixture("statements/td_chequing.txt").read)

    original = upload_pdf("TD_UNLIMITED_CHEQUING_ACCOUNT_1234-5678901_Apr_30-May_29_2026.pdf")
    original.publish

    renamed = upload_pdf("statement-unlocked.pdf")
    assert_equal original.account, renamed.account
    assert_empty renamed.rows
  end

  test "a later statement for the same bank account goes into the same account" do
    first = upload("rbc_chequing.qfx")
    first.publish

    second = upload("rbc_chequing.qfx")

    assert_equal first.account, second.account
    assert_empty second.rows # everything was imported already
  end

  private
    def ofx(transactions)
      trns = transactions.map { |date, amount, name| "<STMTTRN><DTPOSTED>#{date}<TRNAMT>#{amount}<NAME>#{name}</STMTTRN>" }.join
      "<OFX><STMTRS><CURDEF>CAD<BANKACCTFROM><ACCTID>999<ACCTTYPE>CHECKING</BANKACCTFROM><BANKTRANLIST>#{trns}</BANKTRANLIST></STMTRS></OFX>"
    end

    def upload_pdf(file_name)
      import = @family.imports.create!(type: "StatementImport")
      import.upload_statement!("%PDF-1.7 fake", file_name: file_name)
      import
    end

    def upload(file, account: nil)
      import = @family.imports.create!(type: "StatementImport")
      import.upload_statement!(file_fixture("statements/#{file}").read, account: account)
      import
    end

    def create_account
      @family.accounts.create!(name: "My RBC", balance: 0, currency: "CAD", accountable: Depository.new)
    end

    def materialized_balance(account)
      account.reload # classification is computed by the database
      Balance::Materializer.new(account, strategy: :forward).materialize_balances
      account.reload.balance
    end
end
