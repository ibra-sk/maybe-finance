module Family::StockTrackable
  extend ActiveSupport::Concern

  # Stocks on the watchlist plus any currently held in the family's accounts
  def stocks
    items = watchlist_items.includes(:security).index_by(&:security_id)
    held = accounts.visible.flat_map { |account| account.current_holdings.includes(:security, :account).to_a }
                   .group_by(&:security_id)

    Security.where(id: items.keys | held.keys).order(:ticker).map do |security|
      Stock.new(security: security, family: self, watchlist_item: items[security.id], holdings: held[security.id] || [])
    end
  end

  def stock(security_id)
    stocks.find { |stock| stock.to_param == security_id } or raise ActiveRecord::RecordNotFound
  end

  # Adds a stock picked from the ticker search ("TICKER|MIC") to the watchlist. The value came
  # from provider search results, so it's used as-is rather than resolved again (a failed
  # second lookup would mark the security offline).
  def watch_stock!(ticker_with_mic)
    ticker, mic = ticker_with_mic.to_s.upcase.split("|")
    security = Security.find_or_create_by!(ticker: ticker, exchange_operating_mic: mic.presence)

    watchlist_items.find_or_create_by!(security: security)
  end
end
