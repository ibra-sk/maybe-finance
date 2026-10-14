# Imports QFX/OFX and PDF statements dropped into a folder (STATEMENT_IMPORT_DIR), so downloading
# "transactions" from online banking is all it takes to update MacroFinance.
#
# Each file is claimed by moving it into processing/, then filed under:
#   imported/      published, or every transaction was already in MacroFinance
#   needs-review/  some rows are invalid; the pending import is waiting under Settings > Imports
#   failed/        unreadable file or import error (see the log)
class StatementImport::Folder
  EXTENSIONS = %w[.qfx .ofx .pdf].freeze

  # Skip files modified this recently, which may still be downloading
  SETTLE_TIME = 10.seconds

  attr_reader :path, :family

  def self.from_env
    dir = ENV["STATEMENT_IMPORT_DIR"].presence
    new(File.expand_path(dir)) if dir
  end

  # ponytail: imports into the oldest family, which is the household on a personal instance.
  # Add a per-family folder setting if this ever serves more than one household.
  def initialize(path, family: Family.order(:created_at).first)
    @path = path
    @family = family
  end

  # Returns { "file.qfx" => :imported | :duplicate | :needs_review | :failed }
  def import_all
    return {} unless family && Dir.exist?(path)

    ready_files.to_h { |file| [ File.basename(file), import_file(claim(file)) ] }
  end

  private
    def ready_files
      Dir.children(path).sort.map { |name| File.join(path, name) }.select do |file|
        File.file?(file) &&
          EXTENSIONS.include?(File.extname(file).downcase) &&
          File.mtime(file) < SETTLE_TIME.ago
      end
    end

    def import_file(file)
      import = family.imports.create!(type: "StatementImport")
      import.upload_statement!(File.binread(file), file_name: File.basename(file))

      if import.rows.empty?
        import.destroy!
        file_away(file, "imported", :duplicate)
      elsif !import.publishable?
        file_away(file, "needs-review", :needs_review)
      else
        import.publish
        raise import.error.to_s unless import.complete?

        file_away(file, "imported", :imported)
      end
    rescue => error
      import&.destroy if error.is_a?(StatementImport::ParseError)
      Rails.logger.error("Statement folder import failed for #{File.basename(file)}: #{error.message}")
      file_away(file, "failed", :failed)
    end

    # Renaming is atomic, so overlapping runs never pick up the same file
    def claim(file)
      move(file, "processing")
    end

    def file_away(file, folder, result)
      move(file, folder)
      result
    end

    # Prefix a timestamp since banks reuse names like "download.qfx" for every export
    def move(file, folder)
      dir = File.join(path, folder)
      FileUtils.mkdir_p(dir)

      name = File.basename(file)
      name = "#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{name}" unless folder == "processing"

      File.join(dir, name).tap { |destination| File.rename(file, destination) }
    end
end
