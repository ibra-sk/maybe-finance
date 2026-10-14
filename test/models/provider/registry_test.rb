require "test_helper"

class Provider::RegistryTest < ActiveSupport::TestCase
  test "market data providers need no configuration" do
    assert_instance_of Provider::Frankfurter, Provider::Registry.for_concept(:exchange_rates).get_provider(:frankfurter)
    assert_instance_of Provider::YahooFinance, Provider::Registry.for_concept(:securities).get_provider(:yahoo_finance)
  end
end
