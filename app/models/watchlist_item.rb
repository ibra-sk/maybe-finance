class WatchlistItem < ApplicationRecord
  belongs_to :family
  belongs_to :security

  validates :security_id, uniqueness: { scope: :family_id }
  validates :buy_below, :sell_above, numericality: { greater_than: 0 }, allow_nil: true

  after_create_commit -> { SecurityBackfillJob.perform_later(security) }
end
