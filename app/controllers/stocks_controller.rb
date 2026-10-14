class StocksController < ApplicationController
  FILTERS = %w[all watching owned].freeze
  SORTS = %w[ticker change target].freeze

  def index
    @filter = params[:filter].presence_in(FILTERS) || "all"
    @sort = params[:sort].presence_in(SORTS) || "ticker"
    @stocks = sort(filter(Current.family.stocks))

    @breadcrumbs = [ [ "Home", root_path ], [ "Stocks", nil ] ]
  end

  def show
    @stock = Current.family.stock(params[:id])
    @period = Period.from_key(params[:period].presence_in(Period::PERIODS.keys) || "last_365_days")

    @breadcrumbs = [ [ "Home", root_path ], [ "Stocks", stocks_path ], [ @stock.ticker, nil ] ]
  end

  def new
  end

  def create
    if params[:ticker].blank?
      redirect_to stocks_path, alert: "Pick a stock from the search results."
    else
      item = Current.family.watch_stock!(params[:ticker])
      redirect_to stock_path(item.security_id), notice: "#{item.security.ticker} added to your watchlist."
    end
  end

  # Saving targets or notes also adds an owned stock to the watchlist
  def update
    item = Current.family.watchlist_items.find_or_initialize_by(security: Current.family.stock(params[:id]).security)

    if item.update(watchlist_item_params)
      redirect_to stock_path(params[:id]), notice: "Saved."
    else
      redirect_to stock_path(params[:id]), alert: item.errors.full_messages.to_sentence
    end
  end

  def destroy
    Current.family.watchlist_items.find_by!(security_id: params[:id]).destroy!
    redirect_to stocks_path, notice: "Removed from your watchlist."
  end

  private
    def watchlist_item_params
      params.require(:watchlist_item).permit(:buy_below, :sell_above, :notes)
    end

    def filter(stocks)
      case @filter
      when "watching" then stocks.select(&:watched?)
      when "owned" then stocks.select(&:owned?)
      else stocks
      end
    end

    # Stocks without data sort last
    def sort(stocks)
      case @sort
      when "change" then stocks.sort_by { |s| -(s.day_change&.percent || -Float::INFINITY) }
      when "target" then stocks.sort_by { |s| s.distance_to_target || Float::INFINITY }
      else stocks
      end
    end
end
