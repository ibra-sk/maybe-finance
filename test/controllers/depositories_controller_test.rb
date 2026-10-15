require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "saves the overdraft limit" do
    patch depository_path(@account), params: {
      account: { accountable_type: "Depository", accountable_attributes: { id: @account.accountable_id, overdraft_limit: "750" } }
    }

    assert_equal 750, @account.reload.depository.overdraft_limit
  end

  test "shows overdraft use on the account page" do
    @account.depository.update!(overdraft_limit: 500)
    @account.update!(balance: -200)

    get account_path(@account)

    assert_response :success
    assert_match "Using", response.body
    assert_match "of $500.00 overdraft", response.body
  end
end
