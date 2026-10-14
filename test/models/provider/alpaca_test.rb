require "test_helper"

class Provider::AlpacaTest < ActiveSupport::TestCase
  include WebMock::API

  setup do
    VCR.turn_off!
    @subject = Provider::Alpaca.new(key_id: "key", secret_key: "secret")
  end

  teardown do
    WebMock.reset!
    VCR.turn_on!
  end

  test "search finds an exact ticker with its exchange" do
    stub_alpaca("paper-api.alpaca.markets/v2/assets/BRK.B", symbol: "BRK.B", name: "Berkshire Hathaway Inc. Class B", exchange: "NYSE")

    results = @subject.search_securities("brk-b").data

    assert_equal [ [ "BRK.B", "XNYS", "US" ] ], results.map { |s| [ s.symbol, s.exchange_operating_mic, s.country_code ] }
  end

  test "search returns nothing for an unknown ticker" do
    stub_request(:get, %r{paper-api\.alpaca\.markets/v2/assets/NOPE}).to_return(status: 404, body: "{}")

    response = @subject.search_securities("NOPE")

    assert response.success?
    assert_empty response.data
  end

  test "sends the account keys" do
    request = stub_alpaca("paper-api.alpaca.markets/v2/assets/AAPL", { symbol: "AAPL", name: "Apple Inc.", exchange: "NASDAQ" })
    assert @subject.search_securities("AAPL").success?

    assert_requested request.with(headers: { "APCA-API-KEY-ID" => "key", "APCA-API-SECRET-KEY" => "secret" })
  end

  test "builds a quote from the snapshot" do
    stub_alpaca("data.alpaca.markets/v2/stocks/AAPL/snapshot", {
      latestTrade: { p: 231.5, t: "2026-10-14T19:59:59Z" },
      dailyBar: { o: 228, h: 232, l: 227.1, c: 231.4, v: 1_234_567 },
      prevDailyBar: { c: 229.0 }
    })

    quote = @subject.fetch_security_quote(symbol: "AAPL", exchange_operating_mic: "XNAS").data

    assert_equal 231.5, quote.price
    assert_equal 229.0, quote.previous_close
    assert_equal [ 227.1, 232 ], [ quote.day_low, quote.day_high ]
    assert_equal "USD", quote.currency
    assert_nil quote.year_high
  end

  test "follows bar pages and dates bars in New York time" do
    stub_request(:get, %r{data\.alpaca\.markets/v2/stocks/AAPL/bars})
      .to_return(
        { status: 200, body: { bars: [ { t: "2024-01-02T05:00:00Z", c: 185.64 } ], next_page_token: "abc" }.to_json },
        { status: 200, body: { bars: [ { t: "2024-01-03T05:00:00Z", c: 184.25 } ], next_page_token: nil }.to_json }
      )

    prices = @subject.fetch_security_prices(symbol: "AAPL", exchange_operating_mic: "XNAS", start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 1, 3)).data

    assert_equal [ Date.new(2024, 1, 2), Date.new(2024, 1, 3) ], prices.map(&:date)
    assert_equal [ 185.64, 184.25 ], prices.map(&:price)
    assert_requested :get, %r{page_token=abc}
  end

  private
    def stub_alpaca(path, body)
      stub_request(:get, %r{#{Regexp.escape(path)}(\?|\z)}).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end
end
