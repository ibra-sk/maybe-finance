module Provider::SecurityConcept
  extend ActiveSupport::Concern

  Security = Data.define(:symbol, :name, :logo_url, :exchange_operating_mic, :country_code)
  SecurityInfo = Data.define(:symbol, :name, :links, :logo_url, :description, :kind, :exchange_operating_mic)
  Price = Data.define(:symbol, :date, :price, :currency, :exchange_operating_mic)
  Quote = Data.define(:symbol, :price, :previous_close, :day_high, :day_low, :year_high, :year_low, :volume, :currency, :as_of)

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    raise NotImplementedError, "Subclasses must implement #search_securities"
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_info"
  end

  def fetch_security_price(symbol:, exchange_operating_mic:, date:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_price"
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_prices"
  end

  # Latest (possibly delayed) market quote
  def fetch_security_quote(symbol:, exchange_operating_mic:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_quote"
  end
end
