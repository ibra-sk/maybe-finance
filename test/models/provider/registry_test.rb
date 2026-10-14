require "test_helper"

class Provider::RegistryTest < ActiveSupport::TestCase
  test "market data providers need no configuration" do
    assert_instance_of Provider::Frankfurter, Provider::Registry.for_concept(:exchange_rates).get_provider(:frankfurter)
    assert_instance_of Provider::SecurityRouter, Provider::Registry.for_concept(:securities).get_provider(:security_router)
  end

  test "Alpaca is used for US securities once its keys are set" do
    with_env_overrides ALPACA_API_KEY_ID: nil, ALPACA_API_SECRET_KEY: nil do
      assert_nil Provider::Registry.get_provider(:security_router).alpaca
    end

    with_env_overrides ALPACA_API_KEY_ID: "key", ALPACA_API_SECRET_KEY: "secret" do
      assert_instance_of Provider::Alpaca, Provider::Registry.get_provider(:security_router).alpaca
    end
  end
end
