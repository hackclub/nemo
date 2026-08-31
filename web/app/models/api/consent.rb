module Api
  class Consent < ApplicationRecord
    self.table_name = "api.consent"
    self.primary_key = [:user_id, :capability]

    GRANTED = "granted".freeze
    WITHHELD = "withheld".freeze

    def self.granted?(user_id, capability)
      exists?(user_id: user_id, capability: capability, state: GRANTED)
    end

    def self.states_for(user_id)
      where(user_id: user_id).pluck(:capability, :state).to_h
    end

    def self.granted_count(user_id)
      where(user_id: user_id, state: GRANTED).count
    end

    def self.set!(user_id, capability, granted, via:)
      state = granted ? GRANTED : WITHHELD

      transaction do
        row = find_or_initialize_by(user_id: user_id, capability: capability)
        row.state = state
        row.changed_at = Time.current
        row.changed_via = via
        row.first_granted_at ||= row.changed_at if granted
        row.save!
        ConsentLog.create!(user_id: user_id, capability: capability, state: state, via: via)
        row
      end
    end
  end
end
