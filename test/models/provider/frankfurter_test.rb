require "test_helper"

class Provider::FrankfurterTest < ActiveSupport::TestCase
  include ExchangeRateProviderInterfaceTest

  setup do
    @subject = Provider::Frankfurter.new
  end

  test "keys a weekend rate to the requested date" do
    VCR.use_cassette("frankfurter/weekend_exchange_rate") do
      saturday = Date.parse("2024-01-06")
      response = @subject.fetch_exchange_rate(from: "USD", to: "CAD", date: saturday)

      assert response.success?
      assert_equal saturday, response.data.date
    end
  end
end
