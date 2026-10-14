# US and Canadian security search, info, and daily prices from Yahoo Finance's public
# (unofficial, keyless) endpoints. Only the search and chart endpoints are used because
# they work without Yahoo's cookie/crumb auth.
#
# Tickers are stored in their plain form ("RY" on XTSE, "BRK.B" on XNYS) and translated
# to Yahoo symbols ("RY.TO", "BRK-B") only at the API boundary.
#
# Set YAHOO_FINANCE_URL to override the API host.
class Provider::YahooFinance < Provider
  include SecurityConcept

  # Subclass so errors caught in this provider are raised as Provider::YahooFinance::Error
  Error = Class.new(Provider::Error)

  # Yahoo exchange code => ISO operating MIC
  EXCHANGE_MICS = {
    "NMS" => "XNAS", "NGM" => "XNAS", "NCM" => "XNAS", "NAS" => "XNAS",
    "NYQ" => "XNYS",
    "PCX" => "ARCX",
    "ASE" => "XASE",
    "BTS" => "BATS",
    "PNK" => "OTCM", "OQB" => "OTCM", "OQX" => "OTCM",
    "TOR" => "XTSE",
    "VAN" => "XTSX", "CVE" => "XTSX",
    "NEO" => "NEOE",
    "CNQ" => "XCNQ"
  }.freeze

  # Canadian listings need a Yahoo symbol suffix; US listings don't
  CANADIAN_SUFFIXES = {
    "XTSE" => ".TO",
    "XTSX" => ".V",
    "NEOE" => ".NE",
    "XCNQ" => ".CN"
  }.freeze

  KINDS = { "EQUITY" => "common stock", "ETF" => "etf", "MUTUALFUND" => "mutual fund" }.freeze

  # country_code is ignored on purpose: results always span both US and Canadian listings
  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      response = client.get("v1/finance/search", q: symbol, quotesCount: 25, newsCount: 0)

      JSON.parse(response.body).fetch("quotes", []).filter_map do |quote|
        mic = EXCHANGE_MICS[quote["exchange"]]
        next unless mic && KINDS.key?(quote["quoteType"])

        Security.new(
          symbol: ticker_from_yahoo(quote["symbol"], mic),
          name: quote["longname"] || quote["shortname"],
          logo_url: nil,
          exchange_operating_mic: mic,
          country_code: country_code_for(mic)
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      meta = fetch_chart(symbol, exchange_operating_mic, range: "1d")["meta"]

      SecurityInfo.new(
        symbol: symbol,
        name: meta["longName"] || meta["shortName"],
        links: nil,
        logo_url: nil,
        description: nil,
        kind: KINDS[meta["instrumentType"]],
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic:, date:)
    with_provider_response do
      # Look back a week so weekends and holidays resolve to the last close
      prices = fetch_security_prices(symbol:, exchange_operating_mic:, start_date: date - 7.days, end_date: date)
      raise prices.error unless prices.success?

      price = prices.data.select { |p| p.date <= date }.max_by(&:date)
      raise Error, "No price found for #{symbol} on or before #{date}" unless price

      # Key to the requested date, matching how the price importer carries prices forward
      price.with(date: date.to_date)
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    with_provider_response do
      chart = fetch_chart(
        symbol,
        exchange_operating_mic,
        period1: start_date.to_time(:utc).to_i,
        period2: end_date.to_time(:utc).end_of_day.to_i
      )

      meta = chart["meta"]
      closes = chart.dig("indicators", "quote", 0, "close") || []

      chart.fetch("timestamp", []).zip(closes).filter_map do |timestamp, close|
        next if close.nil?

        Price.new(
          symbol: symbol,
          # Timestamps mark the session open; shift to exchange time to get the trading date
          date: Time.at(timestamp + meta["gmtoffset"].to_i).utc.to_date,
          price: close,
          currency: meta["currency"],
          exchange_operating_mic: exchange_operating_mic
        )
      end
    end
  end

  private
    def fetch_chart(symbol, exchange_operating_mic, **params)
      yahoo_symbol = ticker_to_yahoo(symbol, exchange_operating_mic)
      response = client.get("v8/finance/chart/#{ERB::Util.url_encode(yahoo_symbol)}", interval: "1d", **params)

      JSON.parse(response.body).dig("chart", "result", 0) or
        raise Error, "No chart data found for #{yahoo_symbol}"
    end

    def ticker_to_yahoo(ticker, mic)
      "#{ticker.tr(".", "-")}#{CANADIAN_SUFFIXES[mic]}"
    end

    def ticker_from_yahoo(yahoo_symbol, mic)
      yahoo_symbol.delete_suffix(CANADIAN_SUFFIXES[mic].to_s).tr("-", ".")
    end

    def country_code_for(mic)
      CANADIAN_SUFFIXES.key?(mic) ? "CA" : "US"
    end

    def base_url
      ENV["YAHOO_FINANCE_URL"] || "https://query2.finance.yahoo.com/"
    end

    # ponytail: no throttling or 429 retries. Yahoo rate limits last minutes, so a failed
    # fetch is left for the next sync; add a min request interval if 429s show up in logs.
    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        faraday.request(:retry, {
          max: 2,
          interval: 0.05,
          interval_randomness: 0.5,
          backoff_factor: 2
        })

        faraday.response :raise_error
        # Yahoo rejects requests without a browser-like user agent
        faraday.headers["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"
        faraday.headers["Accept"] = "application/json"
        faraday.headers["Accept-Language"] = "en-US,en;q=0.9"
      end
    end
end
