# US stock and ETF data from Alpaca (https://alpaca.markets). The free "Basic" market data
# plan that comes with any Alpaca account (paper or live) is enough.
#
#   ALPACA_API_KEY_ID / ALPACA_API_SECRET_KEY  account API keys (paper keys work)
#   ALPACA_API_URL   trading API, for symbol lookups (default: paper trading)
#   ALPACA_DATA_URL  market data API
#
# Canadian listings aren't covered; Provider::SecurityRouter sends those to Yahoo Finance.
class Provider::Alpaca < Provider
  include SecurityConcept

  # Subclass so errors caught in this provider are raised as Provider::Alpaca::Error
  Error = Class.new(Provider::Error)

  # Alpaca exchange name => ISO operating MIC
  EXCHANGE_MICS = {
    "NASDAQ" => "XNAS",
    "NYSE" => "XNYS",
    "ARCA" => "ARCX",
    "AMEX" => "XASE",
    "BATS" => "BATS",
    "OTC" => "OTCM"
  }.freeze

  def initialize(key_id:, secret_key:)
    @key_id = key_id
    @secret_key = secret_key
  end

  # Alpaca has no name search, so this only finds an exact ticker match
  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      asset = fetch_asset(symbol)
      next [] unless asset

      [ Security.new(
        symbol: asset["symbol"],
        name: asset["name"],
        logo_url: nil,
        exchange_operating_mic: EXCHANGE_MICS[asset["exchange"]],
        country_code: "US"
      ) ]
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      asset = fetch_asset(symbol) or raise Error, "Unknown symbol #{symbol}"

      SecurityInfo.new(
        symbol: symbol,
        name: asset["name"],
        links: nil,
        logo_url: nil,
        description: nil,
        kind: asset["attributes"].to_a.include?("etf") ? "etf" : "common stock",
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  def fetch_security_quote(symbol:, exchange_operating_mic:)
    with_provider_response do
      # IEX is the real-time feed included in the free plan
      snapshot = JSON.parse(data_client.get("stocks/#{api_symbol(symbol)}/snapshot", feed: "iex").body)
      daily = snapshot["dailyBar"] || {}

      Quote.new(
        symbol: symbol,
        price: snapshot.dig("latestTrade", "p") || daily["c"],
        previous_close: snapshot.dig("prevDailyBar", "c"),
        day_high: daily["h"],
        day_low: daily["l"],
        year_high: nil, # not offered by Alpaca; Stock computes it from stored prices
        year_low: nil,
        volume: daily["v"],
        currency: "USD",
        as_of: snapshot.dig("latestTrade", "t")&.then { |t| Time.zone.parse(t) }
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic:, date:)
    with_provider_response do
      prices = fetch_security_prices(symbol:, exchange_operating_mic:, start_date: date - 7.days, end_date: date)
      raise prices.error unless prices.success?

      price = prices.data.select { |p| p.date <= date }.max_by(&:date)
      raise Error, "No price found for #{symbol} on or before #{date}" unless price

      price.with(date: date.to_date)
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    with_provider_response do
      bars = []
      page_token = nil

      loop do
        params = {
          timeframe: "1Day",
          start: start_date.to_date.iso8601,
            # The free plan can query consolidated (SIP) history, except the most recent 15 minutes
          end: [ end_date.to_date.end_of_day, 16.minutes.ago ].min.utc.iso8601,
          feed: "sip",
          adjustment: "split",
          limit: 10_000,
          page_token: page_token
        }.compact

        body = JSON.parse(data_client.get("stocks/#{api_symbol(symbol)}/bars", params).body)
        bars.concat(body["bars"] || [])
        page_token = body["next_page_token"]
        break if page_token.blank?
      end

      bars.map do |bar|
        Price.new(
          symbol: symbol,
          # Daily bars are stamped at midnight New York time, in UTC
          date: Time.zone.parse(bar["t"]).in_time_zone("America/New_York").to_date,
          price: bar["c"],
          currency: "USD",
          exchange_operating_mic: exchange_operating_mic
        )
      end
    end
  end

  private
    attr_reader :key_id, :secret_key

    def fetch_asset(symbol)
      JSON.parse(trading_client.get("assets/#{api_symbol(symbol)}").body)
    rescue Faraday::ResourceNotFound
      nil
    end

    # Alpaca writes share classes with a dot, e.g. BRK.B
    def api_symbol(symbol)
      ERB::Util.url_encode(symbol.to_s.upcase.tr("-", "."))
    end

    def trading_client
      @trading_client ||= client(ENV["ALPACA_API_URL"].presence || "https://paper-api.alpaca.markets/v2/")
    end

    def data_client
      @data_client ||= client(ENV["ALPACA_DATA_URL"].presence || "https://data.alpaca.markets/v2/")
    end

    def client(url)
      Faraday.new(url: url.end_with?("/") ? url : "#{url}/") do |faraday|
        faraday.request(:retry, {
          max: 2,
          interval: 0.05,
          interval_randomness: 0.5,
          backoff_factor: 2
        })

        faraday.response :raise_error
        faraday.headers["APCA-API-KEY-ID"] = key_id
        faraday.headers["APCA-API-SECRET-KEY"] = secret_key
        faraday.options.timeout = 10
        faraday.options.open_timeout = 5
      end
    end
end
