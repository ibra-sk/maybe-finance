class StatementFolderImportJob < ApplicationJob
  queue_as :scheduled

  # No-op unless STATEMENT_IMPORT_DIR is set
  def perform
    StatementImport::Folder.from_env&.import_all
  end
end
