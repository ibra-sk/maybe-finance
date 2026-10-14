require "test_helper"

class SecuritiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  # Yahoo Finance and Alpaca don't provide logos
  test "search results render without a logo" do
    Security.stubs(:search_provider).returns([
      Security.new(ticker: "AAPL", name: "Apple Inc.", logo_url: nil, exchange_operating_mic: "XNAS", country_code: "US")
    ])

    get securities_url(q: "AAPL", for_id: "ticker", format: :turbo_stream)

    assert_response :success
    assert_match "AAPL|XNAS", response.body
    assert_match "Apple Inc.", response.body
  end
end
