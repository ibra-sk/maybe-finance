class AddOverdraftLimitToDepositories < ActiveRecord::Migration[7.2]
  def change
    add_column :depositories, :overdraft_limit, :decimal, precision: 19, scale: 4
  end
end
