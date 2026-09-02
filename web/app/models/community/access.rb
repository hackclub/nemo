module Community
  class Access
    def self.superadmin?(staff)
      Fd::Access.manager?(staff)
    end

    EVERY_ACCOUNT = "analytics.workspace.read".freeze

    CAPABILITY = {
      "analytics.member.read" => "member.read",
      "analytics.channel.read" => "channel.read",
      "analytics.channel.share" => "channel.share",
      "analytics.grant" => "access.grant",
      "ops.engine.read" => "engine.read",
      "ops.engine.stage" => "engine.stage",
      "ops.engine.sync" => "engine.sync",
      "ops.engine.tune" => "engine.tune",
      "ops.channel.backfill" => "channel.backfill"
    }.freeze

    def self.capability_for(key)
      CAPABILITY.fetch(key.to_s) { raise Permission::Unknown, "#{key} is not a permission" }
    end

    def self.allow?(staff, key, record = nil)
      return staff.present? if key.to_s == EVERY_ACCOUNT

      Authz.may?(staff, capability_for(key), record)
    end

    def self.why_not(staff, key, record = nil)
      return nil if allow?(staff, key, record)
      return "you hold no access yet" if staff.nil? || Authz.held(staff.user_id).empty?
      return Authz.refusal(capability_for(key)) unless Authz.holds?(staff, capability_for(key))

      "that channel is not yours"
    end

    def self.within_scope?(staff, key, record)
      return true unless key.to_s == "analytics.channel.read"
      return true if record.nil?

      Channels::Audience.may_see?(staff, record)
    end
  end
end
