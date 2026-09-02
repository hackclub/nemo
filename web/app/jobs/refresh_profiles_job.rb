class RefreshProfilesJob < ApplicationJob
  queue_as :default

  ASKED_KEY = "profiles/asked".freeze
  ASKED_TTL = 10.minutes
  PER_RUN = CachetClient::FETCH_CAP

  def self.later(user_ids)
    wanted = fresh_asks(Array(user_ids).compact.uniq)
    return if wanted.empty?

    perform_later(wanted)
  rescue StandardError => e
    Rails.logger.error("could not queue a profile refresh: #{e.message}")
  end

  def self.fresh_asks(user_ids)
    user_ids.reject { |id| Rails.cache.exist?("#{ASKED_KEY}/#{id}") }.tap do |asking|
      asking.each { |id| Rails.cache.write("#{ASKED_KEY}/#{id}", true, expires_in: ASKED_TTL) }
    end
  end

  def perform(user_ids)
    CachetClient.profiles(user_ids.first(PER_RUN))
  rescue StandardError => e
    Rails.logger.error("profile refresh failed: #{e.message}")
  end
end
