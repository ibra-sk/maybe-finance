require "test_helper"

class StockTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @security = Security.create!(ticker: "RY", exchange_operating_mic: "XTSE", name: "Royal Bank of Canada")
    Security.any_instance.stubs(:quote).returns(nil)
  end

  test "falls back to stored closes when there is no live quote" do
    add_prices({ 98 => 3.days.ago, 100 => 2.days.ago, 110 => 1.day.ago }, currency: "CAD")
    stock = Stock.new(security: @security, family: @family)

    assert_equal Money.new(110, "CAD"), stock.price
    assert_equal Money.new(100, "CAD"), stock.previous_close
    assert_equal 10.0, stock.day_change.percent
    assert_equal [ Money.new(98, "CAD"), Money.new(110, "CAD") ], stock.year_range
    assert_equal 100, stock.year_range_position
    assert_equal 3, stock.sparkline_series.size
  end

  test "uses the live quote when there is one" do
    quote = Provider::SecurityConcept::Quote.new(symbol: "RY", price: 150, previous_close: 160, day_high: 161, day_low: 149,
                                                 year_high: 200, year_low: 100, volume: 10, currency: "CAD", as_of: Time.current)
    Security.any_instance.stubs(:quote).returns(quote)
    stock = Stock.new(security: @security, family: @family)

    assert_equal Money.new(150, "CAD"), stock.price
    assert_equal "down", stock.day_change.direction
    assert_equal 50, stock.year_range_position
  end

  test "flags targets the price has reached" do
    add_prices({ 100 => 1.day.ago }, currency: "CAD")

    assert_equal :buy, stock_with(buy_below: 105).target_signal
    assert_equal :sell, stock_with(sell_above: 95).target_signal
    assert_nil stock_with(buy_below: 90, sell_above: 120).target_signal
    assert_in_delta 10.0, stock_with(buy_below: 90, sell_above: 120).distance_to_target
  end

  test "family stocks include watched and held securities" do
    held = holdings(:one).security
    @family.watchlist_items.create!(security: @security)

    stocks = @family.stocks

    assert_includes stocks.map(&:security), @security
    assert_includes stocks.map(&:security), held
    assert stocks.find { |s| s.security == held }.owned?
    assert stocks.find { |s| s.security == @security }.watched?
  end

  private
    def add_prices(prices_by_amount, currency:)
      prices_by_amount.each { |amount, date| @security.prices.create!(price: amount, date: date.to_date, currency: currency) }
    end

    def stock_with(**targets)
      Stock.new(security: @security, family: @family, watchlist_item: WatchlistItem.new(family: @family, security: @security, **targets))
    end
end
