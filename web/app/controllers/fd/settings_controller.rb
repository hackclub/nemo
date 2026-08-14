module Fd
  class SettingsController < BaseController
    TABS = { "access" => "Access", "roles" => "Roles", "history" => "Grant history" }.freeze
    WINDOW = 30.days
    DORMANT_AFTER = 30.days

    REFUSALS_SHOWN = 5

    def show
      @tab = TABS.key?(params[:tab]) ? params[:tab] : "access"
      @grants = AccessGrant.live.newest_first.to_a
      @history = AccessGrant.newest_first.limit(50).to_a if @tab == "history"
      @acted = acted_since(WINDOW.ago)
      @last_acted = last_acted
      @dormant = dormant
      @person = chosen
      person_facts if @person
      @used = used_lately if @tab == "roles"
      @names = Names.for(named)
    end

    private

    def chosen
      asked = params[:person].to_s
      @grants.find { |grant| grant.user_id == asked }
    end

    def person_facts
      @role = @person.role
      @did = did_with_it
      @cannot = Permission.keys - Permission.held_by(@role)
      @refused = AuditEntry.where(actor_user_id: @person.user_id, verb: "refused")
        .recent_first.limit(REFUSALS_SHOWN).to_a
      @reads = AccessLog.where(actor_id: @person.user_id, field_class: "identity")
        .where(looked_at: WINDOW.ago..).count
    end

    def used_lately
      counted = AuditEntry.where(occurred_at: WINDOW.ago..).group(:entity_type, :verb).count
      reads = AccessLog.where(field_class: "identity", looked_at: WINDOW.ago..).count

      Permission.keys.to_h do |key|
        tally = Permission.events(key).sum { |event| counted[event.split("/")] || 0 }
        [key, Permission.logged?(key) ? reads : tally]
      end
    end

    def did_with_it
      counted = AuditEntry.where(actor_user_id: @person.user_id)
        .where(occurred_at: WINDOW.ago..)
        .group(:entity_type, :verb).count

      Permission.held_by(@role).to_h do |key|
        [key, Permission.events(key).sum { |event| counted[event.split("/")] || 0 }]
      end
    end

    def holders
      @holders ||= @grants.map(&:user_id)
    end

    def named
      holders + @grants.map(&:granted_by) + Array(@history).flat_map { |grant|
        [grant.user_id, grant.granted_by, grant.revoked_by]
      }.compact
    end

    def acted_since(moment)
      AuditEntry.where(actor_user_id: holders).where(occurred_at: moment..)
        .group(:actor_user_id).count
    end

    def last_acted
      AuditEntry.where(actor_user_id: holders).group(:actor_user_id).maximum(:occurred_at)
    end

    def dormant
      @grants.select do |grant|
        grant.granted_at < DORMANT_AFTER.ago && @last_acted[grant.user_id].nil?
      end
    end
  end
end
