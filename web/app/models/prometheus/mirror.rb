module Prometheus
  class Mirror
    FRESH_FOR = 60.seconds

    def self.freshen(user_id)
      return false if user_id.blank?
      return false unless Roster.configured?
      return false unless Appointment.for_person(user_id).exists?
      return false unless asking_again?(user_id)

      refresh(user_id)
    end

    def self.asking_again?(user_id)
      key = "prometheus/checked/#{user_id}"
      return false if Rails.cache.read(key)

      Rails.cache.write(key, Time.current.to_i, expires_in: FRESH_FOR)
      true
    end

    def self.refresh(user_id)
      return false if user_id.blank?
      return false unless Roster.configured?

      settle(user_id, Roster.channels_for(user_id))
      true
    rescue Roster::Error, Roster::NotConfigured => e
      Rails.logger.warn("[prometheus] could not read #{user_id}: #{e.message}")
      false
    end

    def self.settle(user_id, channels)
      held = rows_for(user_id, channels)
      Appointment.transaction do
        Appointment.for_person(user_id).delete_all
        Appointment.insert_all!(held) if held.any?
      end
      Current.forget_roles
    end

    def self.reconcile_all
      return false unless Roster.configured?

      held = Roster.every_appointment.filter_map { |one| whole_row(one) }.uniq { |row| row.values_at(:user_id, :channel_id) }
      return refuse_to_empty if held.empty? && Appointment.exists?

      Appointment.transaction do
        Appointment.delete_all
        Appointment.insert_all!(held) if held.any?
      end
      Current.forget_roles
      held.size
    rescue Roster::Error, Roster::NotConfigured => e
      Rails.logger.warn("[prometheus] reconcile stopped: #{e.message}")
      false
    end

    def self.refuse_to_empty
      Rails.logger.error(
        "[prometheus] the roster came back empty while #{Appointment.count} rows are held, " \
        "so nothing was changed"
      )
      false
    end

    def self.whole_row(said)
      user_id = said["user_id"].to_s
      return nil if user_id.blank?

      row_for(user_id, said, Time.current)
    end

    def self.rows_for(user_id, channels)
      seen_at = Time.current
      Array(channels).filter_map { |one| row_for(user_id, one, seen_at) }
        .uniq { |row| row[:channel_id] }
    end

    def self.row_for(user_id, said, seen_at)
      channel_id = said["channel_id"].to_s
      role = said["role"].to_s
      return nil if channel_id.blank? || Appointment::ROLES.exclude?(role)

      { user_id: user_id, channel_id: channel_id, role: role, seen_at: seen_at }
    end
  end
end
