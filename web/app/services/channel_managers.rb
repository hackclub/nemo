class ChannelManagers
  TTL = 1.hour
  HELD_FOR = 20.seconds
  METHOD = "admin.roles.listAssignments".freeze
  PAGE = 200
  PAGE_CAP = 20

  def self.role_id
    ENV["SLACK_CHANNEL_MANAGER_ROLE_ID"].presence
  end

  def self.for(channel_id)
    return [] if channel_id.blank?

    freshen(channel_id)
    Api::ChannelManager.user_ids_in(channel_id)
  end

  def self.manages?(channel_id, user_id)
    self.for(channel_id).include?(user_id)
  end

  def self.swept_at(channel_id)
    Api::ChannelSweep.find_by(channel_id: channel_id)&.synced_at
  end

  def self.freshen(channel_id)
    swept = Api::ChannelSweep.find_by(channel_id: channel_id)

    return refresh(channel_id) if swept.nil?
    return unless swept.stale?(TTL)

    refresh(channel_id) if claim(channel_id)
  end

  def self.claim(channel_id)
    Rails.cache.write("channel_managers/lock/#{channel_id}", true,
      expires_in: HELD_FOR, unless_exist: true)
  end

  def self.refresh(channel_id)
    found = fetch(channel_id)
    return if found.nil?

    store(channel_id, found)
  end

  def self.fetch(channel_id)
    return nil if role_id.nil?

    found = []
    cursor = nil
    PAGE_CAP.times do
      page = Slack::ProxyClient.call(METHOD,
        { role_ids: role_id, entity_ids: channel_id, limit: PAGE, cursor: cursor },
        credential: "admin")
      return nil unless page["ok"]

      Array(page["role_assignments"]).each do |row|
        next unless row["entity_id"] == channel_id && row["user_id"].present?

        found << [row["user_id"], row["date_create"]]
      end

      cursor = page.dig("response_metadata", "next_cursor").presence
      break if cursor.nil?
    end
    found
  rescue Slack::ProxyClient::Error, Slack::ProxyClient::NotConfigured => e
    Rails.logger.warn("channel_managers: #{e.class} for #{channel_id}")
    nil
  end

  def self.store(channel_id, found)
    Api::ChannelManager.transaction do
      Api::ChannelManager.where(channel_id: channel_id).delete_all
      Api::ChannelManager.insert_all(rows_for(channel_id, found)) if found.any?
      Api::ChannelSweep.stamp!(channel_id, found.size)
    end
  end

  def self.rows_for(channel_id, found)
    found.uniq { |user_id, _at| user_id }.map do |user_id, at|
      { channel_id: channel_id, user_id: user_id, assigned_at: at ? Time.zone.at(at) : nil }
    end
  end
end
