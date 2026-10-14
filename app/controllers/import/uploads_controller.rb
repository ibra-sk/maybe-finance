class Import::UploadsController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
  end

  def sample_csv
    send_data @import.csv_template.to_csv,
      filename: "#{@import.type.underscore.split('_').first}_sample.csv",
      type: "text/csv",
      disposition: "attachment"
  end

  def update
    return upload_statement if @import.is_a?(StatementImport)

    if csv_valid?(csv_str)
      @import.account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))
      @import.assign_attributes(raw_file_str: csv_str, col_sep: upload_params[:col_sep])
      @import.save!(validate: false)

      redirect_to import_configuration_path(@import, template_hint: true), notice: "CSV uploaded successfully."
    else
      flash.now[:alert] = "Must be valid CSV with headers and at least one row of data"

      render :show, status: :unprocessable_entity
    end
  end

  private
    def upload_statement
      file = params.dig(:import, :statement_file)
      account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))

      @import.upload_statement!(file&.read.to_s, account: account, file_name: file&.original_filename)

      if @import.rows.empty?
        flash.now[:alert] = "All #{@import.statement_transaction_count} transactions in this file are already imported."
        return render :show, status: :unprocessable_entity
      end

      notice = "Found #{@import.statement_transaction_count} transactions"
      notice += ", #{@import.skipped_count} already imported and skipped" if @import.skipped_count.positive?
      notice += @import.account ? ". Importing into #{@import.account.name}." : ". A new account \"#{@import.statement.account_label}\" will be created."

      redirect_to import_clean_path(@import), notice: notice
    rescue StatementImport::PendingImportError => e
      @import.destroy!
      redirect_to import_path(e.pending_import), alert: e.message
    rescue StatementImport::ParseError => e
      flash.now[:alert] = e.message
      render :show, status: :unprocessable_entity
    end

    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def csv_str
      @csv_str ||= upload_params[:csv_file]&.read || upload_params[:raw_file_str]
    end

    def csv_valid?(str)
      begin
        csv = Import.parse_csv_str(str, col_sep: upload_params[:col_sep])
        return false if csv.headers.empty?
        return false if csv.count == 0
        true
      rescue CSV::MalformedCSVError
        false
      end
    end

    def upload_params
      params.require(:import).permit(:raw_file_str, :csv_file, :col_sep)
    end
end
