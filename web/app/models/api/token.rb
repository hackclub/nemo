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

    scope :live, -> { where(revoked_at: nil) }

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

    def self.mint!(owner_user_id, name)
      raise TooMany unless room_for?(owner_user_id)

      key = secret
      row = create!(owner_user_id: owner_user_id, name: name.to_s.strip.first(MAX_NAME),
        prefix: key.first(LEAD.length + SHOWN), digest: digest_of(key))
      [row, key]
    end

    TOUCH_EVERY = 1.minute

    def revoked? = revoked_at.present?

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
  end
end
