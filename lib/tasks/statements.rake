namespace :statements do
  # Words kept as-is when redacting, because they describe a statement's layout rather than
  # the person: months, column headings, and summary labels. Everything else is scrubbed.
  REDACTION_KEEP_WORDS = %w[
    jan feb mar apr may jun jul aug sep sept oct nov dec
    january february march april june july august september october november december
    date dates description transaction transactions posting posted trans activity details
    withdrawal withdrawals withdrawn deposit deposits deposited balance balances
    opening closing previous new starting ending forward brought carried
    total totals subtotal amount amounts credit credits debit debits cr dr
    payment payments purchase purchases interest fee fees charge charges cash advance advances
    statement period from to of page account accounts summary your this the and for on at in
    minimum due limit available rate rates annual
    cheque cheques chequing checking savings visa mastercard card cards rewards points
    td cibc ctfs canadian tire triangle bank
  ].to_set.freeze

  desc "Write a layout-only, redacted text copy of PDF statements for sharing (usage: statements:redact[path/to/file_or_dir]; KEEP_NUMBERS=1 keeps digits)"
  task :redact, [ :path ] => :environment do |_, args|
    path = File.expand_path(args[:path].to_s)
    files = File.directory?(path) ? Dir.glob(File.join(path, "*")).grep(/\.pdf\z/i).sort : [ path ]
    abort "No PDF files found at #{path}" if files.empty? || !File.file?(files.first)

    files.each do |file|
      text = StatementImport::PdfText.extract(File.binread(file))

      redacted = text.gsub(/\p{L}+/) do |word|
        REDACTION_KEEP_WORDS.include?(word.downcase) ? word : word.gsub(/\p{L}/) { |c| c.match?(/\p{Lu}/) ? "X" : "x" }
      end
      redacted = redacted.gsub(/\d/, "9") unless ENV["KEEP_NUMBERS"]
      redacted = redacted.gsub(/[^\x00-\x7F]/, "x") # any non-ASCII leftovers

      output = file.sub(/\.pdf\z/i, ".redacted.txt")
      File.write(output, redacted)
      puts "Wrote #{output}"
    end
  end

  desc "Check that PDF statements can be imported, printing only a summary (usage: statements:check[path/to/file_or_dir])"
  task :check, [ :path ] => :environment do |_, args|
    path = File.expand_path(args[:path].to_s)
    files = File.directory?(path) ? Dir.glob(File.join(path, "*")).grep(/\.pdf\z/i).sort : [ path ]
    abort "No PDF files found at #{path}" if files.empty? || !File.file?(files.first)

    files.each do |file|
      text = StatementImport::PdfText.extract(File.binread(file))
      statement = StatementImport::Pdf.new(StatementImport::Pdf.with_file_name(text, File.basename(file)))
      dates = statement.transactions.map(&:date).minmax

      puts "PASS #{File.basename(file)}"
      puts "     #{statement.account_label}: #{statement.transactions.size} transactions, #{dates.compact.join(" to ")}, balances reconcile"
    rescue StatementImport::ParseError => e
      puts "FAIL #{File.basename(file)}"
      puts "     #{e.message}"
    end
  end
end
