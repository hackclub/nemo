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
      "analytics.message.show" => "message.show",
      "analytics.message.read" => "message.read",
      "analytics.grant" => "access.grant",
      "ops.engine" => "engine.manage",
      "ops.channel.backfill" => "channel.backfill"
    }.freeze

    def self.capability_for(key)
      CAPABILITY.fetch(key.to_s) { raise Authz::Unknown, "#{key} is not a permission" }
    end

    def self.allow?(staff, key, record = nil)
      return staff.present? if key.to_s == EVERY_ACCOUNT

      Authz.may?(staff, capability_for(key), record)
    end

    SCOPE_REFUSALS = { author: "that post is not yours" }.freeze

    def self.why_not(staff, key, record = nil)
      return nil if allow?(staff, key, record)
      return "you hold no access yet" if staff.nil?

      held = capability_for(key)
      return "you hold no access yet" if !Authz.every_account?(held) && Authz.held(staff.user_id).empty?
      return Authz.refusal(held) unless Authz.holds?(staff, held)

      SCOPE_REFUSALS.fetch(Authz.record_scope(held), "that channel is not yours")
    end

    def self.within_scope?(staff, key, record)
      return true unless key.to_s == "analytics.channel.read"
      return true if record.nil?

      Channels::Audience.may_see?(staff, record)
    end
  end
end
