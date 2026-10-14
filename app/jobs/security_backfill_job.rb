class SecurityBackfillJob < ApplicationJob
  queue_as :medium_priority

  HISTORY = 5.years

  # Gives a newly tracked stock its name and price history right away, instead of waiting for
  # the nightly market data import. Stops at yesterday: stored prices aren't overwritten, so a
  # mid-session price saved as today's close would stick. The nightly import adds today's close.
  def perform(security)
    security.import_provider_details
    security.import_provider_prices(start_date: HISTORY.ago.to_date, end_date: Date.current.prev_day)
  end
end
