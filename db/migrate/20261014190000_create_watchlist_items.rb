class CreateWatchlistItems < ActiveRecord::Migration[7.2]
  def change
    create_table :watchlist_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :security, null: false, foreign_key: true, type: :uuid
      t.decimal :buy_below, precision: 19, scale: 4
      t.decimal :sell_above, precision: 19, scale: 4
      t.text :notes

      t.timestamps
    end

    add_index :watchlist_items, %i[family_id security_id], unique: true
  end
end
