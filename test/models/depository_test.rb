require "test_helper"

class DepositoryTest < ActiveSupport::TestCase
  setup do
    @depository = accounts(:depository).depository
    @account = @depository.account # same object the depository reads the balance from
  end

  test "available funds include the overdraft limit" do
    @depository.overdraft_limit = 500
    @account.balance = 120

    assert_equal Money.new(620, "USD"), @depository.available_funds_money
    assert_nil @depository.overdraft_used_money
    assert_not @depository.over_overdraft_limit?
  end

  test "tracks overdraft use when the balance is negative" do
    @depository.overdraft_limit = 500
    @account.balance = -200

    assert_equal Money.new(200, "USD"), @depository.overdraft_used_money
    assert_equal Money.new(300, "USD"), @depository.available_funds_money
    assert_not @depository.over_overdraft_limit?

    @account.balance = -650
    assert @depository.over_overdraft_limit?
  end

  test "any negative balance is over the limit when no overdraft is set" do
    @account.balance = -10

    assert_nil @depository.available_funds_money
    assert @depository.over_overdraft_limit?
  end
end
