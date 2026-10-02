module Api
  class Consent < ApplicationRecord
    self.table_name = "api.consent"

    GRANTED = "granted".freeze
    WITHHELD = "withheld".freeze

    def self.granted?(user_id, app_id, capability)
      where(user_id: user_id, capability: capability, state: GRANTED)
        .where("app_id = ? OR app_id IS NULL", app_id)
        .exists?
    end

    def self.everywhere?(user_id, capability)
      exists?(user_id: user_id, app_id: nil, capability: capability, state: GRANTED)
    end

    def self.states_for(user_id)
      where(user_id: user_id).pluck(:app_id, :capability, :state)
        .to_h { |app_id, capability, state| [[app_id, capability], state] }
    end

    def self.granted_count(user_id)
      where(user_id: user_id, state: GRANTED).count
    end

    def self.set!(user_id, app_id, capability, granted, via:)
      state = granted ? GRANTED : WITHHELD
      now = Time.current

      transaction do
        held = where(user_id: user_id, capability: capability)
        held = app_id.nil? ? held.where(app_id: nil) : held.where(app_id: app_id)
        row = held.take

        if row
          row.update!(state: state, changed_at: now, changed_via: via,
            first_granted_at: row.first_granted_at || (now if granted))
        else
          create!(user_id: user_id, app_id: app_id, capability: capability, state: state,
            changed_at: now, changed_via: via, first_granted_at: (now if granted))
        end

        ConsentLog.create!(user_id: user_id, app_id: app_id, capability: capability,
          state: state, via: via)
      end
    end
  end
end
