module Fd
  class SettingsController < BaseController
    skip_before_action :needs_the_engine
    permit "access.read", unless: :just_me?

    TABS = { "access" => "Access", "roles" => "Roles", "sections" => "Sections",
             "usage" => "Usage", "history" => "Grant history",
             "activity" => "Activity", "you" => "You",
             "appearance" => "Appearance" }.freeze
    MINE = %w[you activity appearance].freeze
    WINDOW = 30.days
    DORMANT_AFTER = 30.days

    REFUSALS_SHOWN = 5
    KINDS_SHOWN = 3
    DORMANT_SHOWN = 2

    Load = Struct.new(:user_id, :role, :cases, :actions, :reversals, :reads, :refused,
      :weight, :share, keyword_init: true)

    def show
      @tab = tab
      @tabs = may_read_access? ? TABS : TABS.slice(*MINE)
      return activity_facts if @tab == "activity"
      return appearance_facts if @tab == "appearance"
      return you_facts if just_me?

      @grants = AccessGrant.live.newest_first.to_a
      @linked = StaffSlack.live.pluck(:staff_user_id)
      @history = AccessGrant.newest_first.limit(50).to_a if @tab == "history"
      @acted = acted_since(WINDOW.ago)
      @last_acted = last_acted
      @dormant = dormant
      @person = chosen
      grant_facts if @person
      @used = used_lately if @tab == "roles"
      usage_facts if @tab == "usage"
      deed_facts if @person && @tab == "usage"
      @counts = tab_counts
      @names = Names.for(named)
    end

    private

    def page_section
      Fd::Flag.on?(:fire_engine) ? "fd" : "mn"
    end

    def tab
      @tab ||= TABS.key?(params[:tab]) ? params[:tab] : (may_read_access? ? "access" : "you")
    end

    def just_me?
      MINE.include?(tab)
    end

    def may_read_access?
      current_staff&.may?("access.read")
    end

    def activity_facts
      @deeds = Deeds.new(current_staff.user_id, since: WINDOW.ago)
      @yours = mine_lately
      @counts = may_read_access? ? tally_without_grants : {}
      @names = Names.for(@deeds.member_ids + [current_staff.user_id])
    end

    def appearance_facts
      @counts = may_read_access? ? tally_without_grants : {}
    end

    def you_facts
      @counts = may_read_access? ? tally_without_grants : {}
      @account = StaffSlack.find_by(staff_user_id: current_staff.user_id)
      @linkable = Slack::Oauth.configured?
      @yours = mine_lately
    end

    def mine_lately
      me = current_staff.user_id
      tallies = AuditEntry.where(actor_user_id: me, occurred_at: WINDOW.ago..)
        .group(:entity_type, :verb).count
      {
        cases: AuditEntry.where(actor_user_id: me, entity_type: "case")
          .where.not(verb: "refused").where(occurred_at: WINDOW.ago..)
          .distinct.count(:entity_id),
        actions: tallies[%w[action performed]].to_i,
        reads: AccessLog.where(actor_id: me, field_class: "identity",
          looked_at: WINDOW.ago..).count,
        refused: AuditEntry.where(actor_user_id: me, verb: "refused",
          occurred_at: WINDOW.ago..).count
      }
    end

    def tab_counts
      { "access" => @grants.size, "roles" => Permission.keys.size,
        "history" => AccessGrant.count }
    end

    def tally_without_grants
      { "access" => AccessGrant.live.count, "roles" => Permission.keys.size,
        "history" => AccessGrant.count }
    end

    def chosen
      asked = params[:person].to_s
      @grants.find { |grant| grant.user_id == asked }
    end

    def grant_facts
      @role = @person.role
      @cannot = Permission.keys - Permission.held_by(@role)
    end

    def deed_facts
      @mine = @load.find { |row| row.user_id == @person.user_id }
      @did = did_with_it
      @reads = @read_counts[@person.user_id].to_i
      @refused = AuditEntry.where(actor_user_id: @person.user_id, verb: "refused")
        .recent_first.limit(REFUSALS_SHOWN).to_a
      @asked = Permission.keys.find { |key| key == params[:did].to_s }
      @deeds = Deeds.new(@person.user_id, since: WINDOW.ago, only: @asked)
    end

    def used_lately
      counted = AuditEntry.where(occurred_at: WINDOW.ago..).group(:entity_type, :verb).count
      reads = AccessLog.where(field_class: "identity", looked_at: WINDOW.ago..).count

      Permission.keys.to_h do |key|
        tally = Permission.events(key).sum { |event| counted[event.split("/")] || 0 }
        [key, Permission.logged?(key) ? reads : tally]
      end
    end

    def usage_facts
      @read_counts = identity_reads
      @reads_total = @read_counts.values.sum
      @top_reader = @read_counts.max_by { |_who, count| count }
      @given = AccessGrant.where(granted_at: WINDOW.ago..).count
      @taken_back = AccessGrant.where(revoked_at: WINDOW.ago..).count
      @refused_total = refusals.count
      @refused_kinds = refused_kinds
      @load = load_rows
    end

    def identity_reads
      AccessLog.where(field_class: "identity", looked_at: WINDOW.ago..)
        .group(:actor_id).count
    end

    def refusals
      AuditEntry.where(verb: "refused", occurred_at: WINDOW.ago..)
    end

    def refused_kinds
      refusals.group(Arel.sql("after ->> 'permission'")).count
        .reject { |key, _count| key.blank? }
        .sort_by { |_key, count| -count }.first(KINDS_SHOWN)
    end

    def load_rows
      tallies = AuditEntry.where(actor_user_id: holders, occurred_at: WINDOW.ago..)
        .group(:actor_user_id, :entity_type, :verb).count
      touched = AuditEntry.where(actor_user_id: holders, entity_type: "case")
        .where.not(verb: "refused").where(occurred_at: WINDOW.ago..)
        .group(:actor_user_id).distinct.count(:entity_id)

      rows = @grants.map { |grant| load_row(grant, tallies, touched) }
      whole = rows.sum(&:weight)
      rows.each { |row| row.share = whole.zero? ? 0 : (row.weight * 100.0 / whole).round }
      rows.sort_by { |row| [-row.weight, row.user_id] }
    end

    def load_row(grant, tallies, touched)
      mine = tallies.select { |(who, _type, _verb), _count| who == grant.user_id }
      refused = mine.sum { |(_who, _type, verb), count| verb == "refused" ? count : 0 }

      Load.new(user_id: grant.user_id, role: grant.role,
        cases: touched[grant.user_id].to_i,
        actions: tallies[[grant.user_id, "action", "performed"]].to_i,
        reversals: tallies[[grant.user_id, "action", "reversed"]].to_i,
        reads: @read_counts[grant.user_id].to_i,
        refused: refused, weight: mine.values.sum - refused, share: 0)
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
      holders + @grants.map(&:granted_by) + Array(@top_reader&.first) +
        Array(@deeds&.member_ids) +
        Array(@history).flat_map { |grant|
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
