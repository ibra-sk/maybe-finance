# Exchange rates from Frankfurter (https://frankfurter.dev), an open source API over
# European Central Bank reference rates. No API key. Rates exist for business days only;
# ExchangeRate::Importer gapfills weekends and holidays.
#
# Set FRANKFURTER_URL to point at a self-hosted instance.
class Provider::Frankfurter < Provider
  include ExchangeRateConcept

  # Subclass so errors caught in this provider are raised as Provider::Frankfurter::Error
  Error = Class.new(Provider::Error)

  def fetch_exchange_rate(from:, to:, date:)
    with_provider_response do
      response = client.get(date.to_s, base: from, symbols: to)
      rate = JSON.parse(response.body).dig("rates", to)

      raise Error, "No rate found for #{from} to #{to} on #{date}" if rate.nil?

      # Frankfurter answers with the closest prior business day; key the result to the
      # requested date so it is cached where callers will look it up.
      Rate.new(date: date.to_date, from:, to:, rate:)
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    with_provider_response do
      response = client.get("#{start_date}..#{end_date}", base: from, symbols: to)
      rates_by_date = JSON.parse(response.body).fetch("rates", {})

      rates_by_date.filter_map do |date, rates|
        rate = rates[to]
        Rate.new(date: date.to_date, from:, to:, rate:) if rate
      end
    end
  end

  private
    def base_url
      ENV["FRANKFURTER_URL"] || "https://api.frankfurter.dev/v1/"
    end

    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        faraday.request(:retry, {
          max: 2,
          interval: 0.05,
          interval_randomness: 0.5,
          backoff_factor: 2
        })

        faraday.response :raise_error
      end
    end
end
