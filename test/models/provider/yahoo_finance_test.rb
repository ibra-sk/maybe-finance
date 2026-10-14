require "test_helper"

class Provider::YahooFinanceTest < ActiveSupport::TestCase
  include WebMock::API

  # Yahoo rate-limits aggressively, so these tests stub responses shaped like Yahoo's
  # instead of recording cassettes.
  setup do
    VCR.turn_off!
    @subject = Provider::YahooFinance.new
  end

  teardown do
    WebMock.reset!
    VCR.turn_on!
  end

  test "search keeps US and Canadian listings and stores plain tickers" do
    stub_yahoo(%r{/v1/finance/search}, quotes: [
      { symbol: "RY.TO", exchange: "TOR", quoteType: "EQUITY", longname: "Royal Bank of Canada" },
      { symbol: "RY", exchange: "NYQ", quoteType: "EQUITY", longname: "Royal Bank of Canada" },
      { symbol: "BBD-B.TO", exchange: "TOR", quoteType: "EQUITY", shortname: "Bombardier" },
      { symbol: "XEQT.TO", exchange: "TOR", quoteType: "ETF", longname: "iShares Core Equity ETF" },
      { symbol: "RY.L", exchange: "LSE", quoteType: "EQUITY", longname: "Unsupported exchange" },
      { symbol: "^RY", exchange: "TOR", quoteType: "INDEX", longname: "Not a security" }
    ])

    results = @subject.search_securities("RY").data

    assert_equal [ %w[RY XTSE CA], %w[RY XNYS US], %w[BBD.B XTSE CA], %w[XEQT XTSE CA] ],
                 results.map { |s| [ s.symbol, s.exchange_operating_mic, s.country_code ] }
  end

  test "fetches Canadian prices in CAD on exchange trading dates" do
    # 2024-01-02 and 2024-01-03 09:30 Toronto time (UTC-5), second day has no close
    stub_yahoo(%r{/v8/finance/chart/RY\.TO}, chart(
      timestamps: [ 1704205800, 1704292200 ], closes: [ 133.5, nil ], currency: "CAD", gmtoffset: -18000
    ))

    prices = @subject.fetch_security_prices(
      symbol: "RY", exchange_operating_mic: "XTSE", start_date: Date.parse("2024-01-01"), end_date: Date.parse("2024-01-03")
    ).data

    assert_equal 1, prices.size
    assert_equal Date.parse("2024-01-02"), prices.first.date
    assert_equal 133.5, prices.first.price
    assert_equal "CAD", prices.first.currency
  end

  test "single price on a weekend uses the last close, keyed to the requested date" do
    # Friday 2024-01-05 09:30 New York time
    stub_yahoo(%r{/v8/finance/chart/BRK-B}, chart(timestamps: [ 1704465000 ], closes: [ 362.1 ], currency: "USD", gmtoffset: -18000))

    saturday = Date.parse("2024-01-06")
    price = @subject.fetch_security_price(symbol: "BRK.B", exchange_operating_mic: "XNYS", date: saturday).data

    assert_equal saturday, price.date
    assert_equal 362.1, price.price
  end

  test "returns an error response when Yahoo rate-limits" do
    stub_request(:get, %r{query2\.finance\.yahoo\.com}).to_return(status: 429)

    response = @subject.fetch_security_info(symbol: "AAPL", exchange_operating_mic: "XNAS")

    assert_not response.success?
    assert_instance_of Provider::YahooFinance::Error, response.error
  end

  private
    def stub_yahoo(url, body)
      stub_request(:get, url).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end

    def chart(timestamps:, closes:, currency:, gmtoffset:)
      {
        chart: {
          result: [ {
            meta: { currency: currency, gmtoffset: gmtoffset, longName: "Test", instrumentType: "EQUITY" },
            timestamp: timestamps,
            indicators: { quote: [ { close: closes } ] }
          } ]
        }
      }
    end
end
