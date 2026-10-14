# Sends each security to the provider that covers its market: Canadian listings to Yahoo
# Finance, everything else to Alpaca when its keys are set (Yahoo Finance otherwise).
class Provider::SecurityRouter < Provider
  include SecurityConcept

  CANADIAN_MICS = Provider::YahooFinance::CANADIAN_SUFFIXES.keys.freeze

  attr_reader :yahoo, :alpaca

  def initialize(yahoo:, alpaca: nil)
    @yahoo = yahoo
    @alpaca = alpaca
  end

  # Alpaca only matches exact US tickers, so its result is listed first and Yahoo adds name
  # matches and Canadian listings. Either one failing just leaves its results out.
  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      [ alpaca, yahoo ].compact
        .flat_map { |provider| provider.search_securities(symbol, country_code:, exchange_operating_mic:).data || [] }
        .uniq { |security| [ security.symbol, security.exchange_operating_mic ] }
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    provider_for(exchange_operating_mic).fetch_security_info(symbol:, exchange_operating_mic:)
  end

  def fetch_security_quote(symbol:, exchange_operating_mic:)
    provider_for(exchange_operating_mic).fetch_security_quote(symbol:, exchange_operating_mic:)
  end

  def fetch_security_price(symbol:, exchange_operating_mic:, date:)
    provider_for(exchange_operating_mic).fetch_security_price(symbol:, exchange_operating_mic:, date:)
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    provider_for(exchange_operating_mic).fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
  end

  def provider_for(exchange_operating_mic)
    CANADIAN_MICS.include?(exchange_operating_mic) || alpaca.nil? ? yahoo : alpaca
  end
end
