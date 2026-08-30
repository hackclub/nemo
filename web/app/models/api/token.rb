require "securerandom"

module Api
  class Token < ApplicationRecord
    self.table_name = "api.token"

    LEAD = "nemo_live_".freeze
    ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".chars.freeze
    LENGTH = 20
    SHOWN = 4
    MAX_NAME = 60

    class TooMany < StandardError; end

    LIVES = {
      "30" => 30.days,
      "90" => 90.days,
      "365" => 365.days,
      "never" => nil
    }.freeze

    LIFE_WORDS = {
      "30" => "30 days",
      "90" => "90 days",
      "365" => "a year",
      "never" => "no expiry"
    }.freeze

    DEFAULT_LIFE = "90".freeze

    scope :live, lambda {
      where(revoked_at: nil).where("expires_at IS NULL OR expires_at > now()")
    }

    def self.for_owner(user_id)
      where(owner_user_id: user_id).order(revoked_at: :asc, created_at: :desc)
    end

    def self.room_for?(user_id)
      live.where(owner_user_id: user_id).count < Setting.value("tokens_per_owner")
    end

    def self.digest_of(secret)
      Digest::SHA256.hexdigest(secret.to_s)
    end

    def self.secret
      LEAD + Array.new(LENGTH) { ALPHABET[SecureRandom.random_number(ALPHABET.size)] }.join
    end

    def self.life_for(asked)
      LIVES.key?(asked.to_s) ? asked.to_s : DEFAULT_LIFE
    end

    def self.dies_on(asked)
      span = LIVES.fetch(life_for(asked))
      span && span.from_now
    end

    def self.mint!(owner_user_id, name, lasting: DEFAULT_LIFE)
      raise TooMany unless room_for?(owner_user_id)

      key = secret
      row = create!(owner_user_id: owner_user_id, name: name.to_s.strip.first(MAX_NAME),
        prefix: key.first(LEAD.length + SHOWN), digest: digest_of(key),
        expires_at: dies_on(lasting))
      [row, key]
    end

    TOUCH_EVERY = 1.minute

    def revoked? = revoked_at.present?

    def expired? = expires_at.present? && expires_at <= Time.current

    def spent? = revoked? || expired?

    def used!
      return if last_used_at && last_used_at > TOUCH_EVERY.ago

      update_column(:last_used_at, Time.current)
    end

    def revoke!(by:)
      update!(revoked_at: Time.current, revoked_by: by)
    end

    def rate
      rate_limit || Setting.value("rate_per_minute")
    end

    def shown
      "#{prefix}…"
    end

    def dies_in
      return "never" if expires_at.nil?
      return "expired" if expired?

      "#{((expires_at - Time.current) / 1.day).ceil}d"
    end
  end
end
