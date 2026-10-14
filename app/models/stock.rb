# A security as the Stocks page sees it: market data, plus the family's watchlist settings
# and current position. Built by Family#stocks; not persisted.
class Stock
  attr_reader :security, :family, :watchlist_item, :holdings

  delegate :ticker, :exchange_operating_mic, :country_code, to: :security

  def initialize(security:, family:, watchlist_item: nil, holdings: [])
    @security = security
    @family = family
    @watchlist_item = watchlist_item
    @holdings = holdings
  end

  def to_param
    security.id
  end

  def name
    security.name.presence || ticker
  end

  def watched?
    watchlist_item.present?
  end

  def owned?
    holdings.any?
  end

  # ================================
  #           Market data
  # ================================

  def quote
    return @quote if defined?(@quote)
    @quote = security.quote
  end

  def currency
    quote&.currency || recent_closes.first&.currency || family.currency
  end

  # Latest quote, falling back to the last stored daily close when the provider is unavailable
  def price
    amount = quote&.price || recent_closes.first&.price
    Money.new(amount, currency) if amount
  end

  def price_as_of
    quote&.as_of || recent_closes.first&.date
  end

  def previous_close
    amount = quote ? quote.previous_close : recent_closes.second&.price
    Money.new(amount, currency) if amount
  end

  def day_change
    Trend.new(current: price, previous: previous_close) if price && previous_close
  end

  def day_range
    [ quote&.day_low, quote&.day_high ].then { |range| range.all? ? range.map { |amount| Money.new(amount, currency) } : nil }
  end

  def year_range
    low, high = quote&.year_low && quote&.year_high ? [ quote.year_low, quote.year_high ] : stored_year_range
    [ Money.new(low, currency), Money.new(high, currency) ] if low && high
  end

  # Where the current price sits in its 52-week range, from 0 (low) to 100 (high)
  def year_range_position
    low, high = year_range
    return nil unless price && low && high && high > low

    ((price - low).amount / (high - low).amount * 100).clamp(0, 100).round
  end

  def volume
    quote&.volume
  end

  def price_series(period)
    values = security.prices
                     .where(currency: currency, date: period.start_date..period.end_date)
                     .order(:date)
                     .map { |p| { date: p.date, value: Money.new(p.price, p.currency) } }

    Series.from_raw_values(values) if values.size >= 2
  end

  def sparkline_series
    price_series(Period.last_30_days)
  end

  # ================================
  #       Watchlist and position
  # ================================

  def buy_below
    Money.new(watchlist_item.buy_below, currency) if watchlist_item&.buy_below
  end

  def sell_above
    Money.new(watchlist_item.sell_above, currency) if watchlist_item&.sell_above
  end

  # :buy or :sell when the price has reached a target
  def target_signal
    return nil unless price

    if buy_below && price <= buy_below
      :buy
    elsif sell_above && price >= sell_above
      :sell
    end
  end

  # How far the price must move to reach the nearest target, as a percent (for sorting)
  def distance_to_target
    return nil unless price && price.amount.positive?

    [ buy_below, sell_above ].compact.map { |target| ((target - price).amount / price.amount * 100).abs }.min
  end

  def notes
    watchlist_item&.notes
  end

  def shares
    holdings.sum(&:qty)
  end

  def market_value
    to_family_currency(holdings.map(&:amount_money)) if owned?
  end

  # Market value vs. average cost across all accounts holding this stock
  def gain
    return nil unless owned?

    cost = to_family_currency(holdings.map { |h| h.avg_cost * h.qty })
    Trend.new(current: market_value, previous: cost)
  end

  def trades
    Entry.joins(:account)
         .where(accounts: { family_id: family.id }, entryable: Trade.where(security: security))
         .includes(:account)
         .reverse_chronological
  end

  private
    def recent_closes
      @recent_closes ||= security.prices.order(date: :desc).limit(2).to_a
    end

    def stored_year_range
      security.prices.where(currency: currency, date: 1.year.ago.to_date..).pick(Arel.sql("MIN(price), MAX(price)"))
    end

    def to_family_currency(amounts)
      amounts.map { |money| money.exchange_to(family.currency, fallback_rate: 1) }.sum(Money.new(0, family.currency))
    end
end
