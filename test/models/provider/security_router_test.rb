require "test_helper"

class Provider::SecurityRouterTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @yahoo = Provider::YahooFinance.new
    @alpaca = Provider::Alpaca.new(key_id: "key", secret_key: "secret")
    @router = Provider::SecurityRouter.new(yahoo: @yahoo, alpaca: @alpaca)
  end

  test "Canadian listings go to Yahoo, US listings to Alpaca" do
    assert_same @yahoo, @router.provider_for("XTSE")
    assert_same @yahoo, @router.provider_for("XTSX")
    assert_same @alpaca, @router.provider_for("XNAS")
    assert_same @alpaca, @router.provider_for(nil)
  end

  test "everything goes to Yahoo without Alpaca keys" do
    router = Provider::SecurityRouter.new(yahoo: @yahoo)

    assert_same @yahoo, router.provider_for("XNYS")
  end

  test "search merges both providers and survives one failing" do
    aapl = Provider::SecurityConcept::Security.new(symbol: "AAPL", name: "Apple", logo_url: nil, exchange_operating_mic: "XNAS", country_code: "US")
    ry = Provider::SecurityConcept::Security.new(symbol: "RY", name: "RBC", logo_url: nil, exchange_operating_mic: "XTSE", country_code: "CA")

    @alpaca.stubs(:search_securities).returns(provider_success_response([ aapl ]))
    @yahoo.stubs(:search_securities).returns(provider_success_response([ aapl, ry ]))
    assert_equal %w[AAPL RY], @router.search_securities("x").data.map(&:symbol)

    @yahoo.stubs(:search_securities).returns(provider_error_response(Provider::Error.new("429")))
    assert_equal %w[AAPL], @router.search_securities("x").data.map(&:symbol)
  end
end
