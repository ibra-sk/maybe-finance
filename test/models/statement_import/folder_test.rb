require "test_helper"

class StatementImport::FolderTest < ActiveSupport::TestCase
  setup do
    @family = Family.create!(name: "Folder family", currency: "CAD")
    @dir = Dir.mktmpdir
    @folder = StatementImport::Folder.new(@dir, family: @family)
  end

  teardown do
    FileUtils.remove_entry(@dir)
  end

  test "imports dropped statements and files them away" do
    drop "rbc_chequing.qfx"
    drop "cibc_visa.qfx", as: "Download.QFX"

    assert_equal({ "Download.QFX" => :imported, "rbc_chequing.qfx" => :imported }, @folder.import_all)

    assert_equal [ "CIBC Credit Card ••9876", "RBC Chequing ••1234" ], @family.accounts.order(:name).pluck(:name)
    assert_equal 2, files_in("imported").size
    assert_empty files_in("processing")
  end

  test "a statement that was already imported is filed without creating an import" do
    drop "rbc_chequing.qfx"
    @folder.import_all

    drop "rbc_chequing.qfx"

    assert_no_difference -> { @family.imports.count } do
      assert_equal({ "rbc_chequing.qfx" => :duplicate }, @folder.import_all)
    end
  end

  test "unreadable files go to failed" do
    drop "not-a-statement.ofx", content: "date,amount\n2024-01-01,5"

    assert_equal({ "not-a-statement.ofx" => :failed }, @folder.import_all)
    assert_equal 1, files_in("failed").size
    assert_empty @family.imports.reload
  end

  test "ignores other files and ones still being written" do
    drop "notes.txt", content: "hello"
    drop "rbc_chequing.qfx", age: 0.seconds

    assert_empty @folder.import_all
  end

  private
    def drop(fixture, as: fixture, content: nil, age: 1.minute)
      path = File.join(@dir, as)
      File.write(path, content || file_fixture("statements/#{fixture}").read)
      File.utime(age.ago.to_time, age.ago.to_time, path)
    end

    def files_in(subfolder)
      Dir.glob(File.join(@dir, subfolder, "*"))
    end
end
