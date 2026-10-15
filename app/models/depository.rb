class Depository < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "checking" => { short: "Checking", long: "Checking" },
    "savings" => { short: "Savings", long: "Savings" },
    "hsa" => { short: "HSA", long: "Health Savings Account" },
    "cd" => { short: "CD", long: "Certificate of Deposit" },
    "money_market" => { short: "MM", long: "Money Market" }
  }.freeze

  class << self
    def display_name
      "Cash"
    end

    def color
      "#875BF7"
    end

    def classification
      "asset"
    end

    def icon
      "landmark"
    end
  end

  validates :overdraft_limit, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # The overdraft is credit the bank extends, not money the account holds, so it doesn't change
  # the balance or net worth; it's what the account can still spend on top of its balance.
  def overdraft_limit_money
    Money.new(overdraft_limit, account.currency) if overdraft_limit&.positive?
  end

  def available_funds_money
    account.balance_money + overdraft_limit_money if overdraft_limit_money
  end

  def overdraft_used_money
    -account.balance_money if account.balance.negative?
  end

  def over_overdraft_limit?
    overdraft_used_money.present? && overdraft_used_money > (overdraft_limit_money || Money.new(0, account.currency))
  end
end
