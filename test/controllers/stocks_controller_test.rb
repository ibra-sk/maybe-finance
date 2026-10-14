require "test_helper"

class StocksControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @aapl = securities(:aapl) # held in the investment account fixture
    Security.any_instance.stubs(:quote).returns(nil)
  end

  test "lists watched and owned stocks, with filters and sorting" do
    @family.watchlist_items.create!(security: securities(:msft))

    get stocks_url
    assert_response :success
    assert_select "a[href='#{stock_path(@aapl)}']"
    assert_select "a[href='#{stock_path(securities(:msft))}']"

    get stocks_url(filter: "watching", sort: "change")
    assert_response :success
    assert_select "a[href='#{stock_path(@aapl)}']", count: 0
  end

  test "shows a stock" do
    get stock_url(@aapl, period: "last_30_days")
    assert_response :success
    assert_select "h1", text: "AAPL"
  end

  test "adds a stock picked from search to the watchlist" do
    assert_difference -> { @family.watchlist_items.count } do
      assert_enqueued_with(job: SecurityBackfillJob) do
        post stocks_url, params: { ticker: "SHOP|XTSE" }
      end
    end

    security = Security.find_by!(ticker: "SHOP", exchange_operating_mic: "XTSE")
    assert_not security.offline?
    assert_redirected_to stock_url(security)
  end

  test "saving targets on an owned stock adds it to the watchlist" do
    patch stock_url(@aapl), params: { watchlist_item: { buy_below: "180", notes: "Wait for a dip" } }

    item = @family.watchlist_items.find_by!(security: @aapl)
    assert_equal 180, item.buy_below
    assert_redirected_to stock_url(@aapl)
  end

  test "removes a stock from the watchlist" do
    item = @family.watchlist_items.create!(security: securities(:msft))

    delete stock_url(item.security)

    assert_not WatchlistItem.exists?(item.id)
    assert_redirected_to stocks_url
  end
end
