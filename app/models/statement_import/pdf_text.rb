# Extracts the text of a PDF bank statement with poppler's `pdftotext -layout`, which keeps
# table columns lined up. Permission-locked statements (password only needed to edit) read
# fine; statements that need a password to open are not supported.
module StatementImport::PdfText
  Error = StatementImport::ParseError

  def self.extract(pdf_data)
    text, error, status = Open3.capture3("pdftotext", "-layout", "-enc", "UTF-8", "-", "-", stdin_data: pdf_data, binmode: true)
    raise Error, "Could not read the PDF: #{error.strip.presence || "pdftotext failed"}" unless status.success?

    text.force_encoding(Encoding::UTF_8)
  rescue Errno::ENOENT
    raise Error, "pdftotext is not installed (install poppler)"
  end
end
