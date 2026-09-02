module Admin
  class OverviewController < BaseController
    WINDOW = 30.days
    CHANGED = %w[grant community_grant capability_grant permission flag channel_audience].freeze
    SHOWN = 8

    def index
      rows = ApplicationRecord.connection.select_all(
        "SELECT role, count(*) AS held FROM app.effective_role GROUP BY role"
      )
      @by_role = rows.to_h { |row| [row["role"], row["held"].to_i] }
      @fd = @by_role
      @holders = ApplicationRecord.connection
        .select_values("SELECT DISTINCT user_id FROM app.effective_role")
      @can_grant = can_grant
      @moved = Fd::Permission.keys.select { |key| Fd::RolePermission.moved?(key) }
      @dark = Fd::Flag::KEYS.reject { |key| Fd::Flag.on?(key) }
      @open_to_all = Channels::Audience::Setting
        .where(audience: Channels::Audience::OPEN).count
      @changed = Fd::AuditEntry.where(entity_type: CHANGED)
        .where(occurred_at: WINDOW.ago..).recent_first.first(SHOWN)
      @dormant = dormant
      @names = Fd::Names.for(@holders + @changed.map(&:actor_user_id) +
        @changed.filter_map { |entry| entry.after&.dig("user_id") })
      @channels = Fd::ChannelNames.for(
        @changed.select { |entry| entry.entity_type == "channel_audience" }.map(&:entity_ref)
      )
    end

    private

    def can_grant
      (Staff.where(community_manager: true).pluck(:user_id) +
        Community::Grant.live.of_family("read")
          .where(role: Community::Permission.superadmin("read")).pluck(:user_id)).uniq.size
    end

    def dormant
      acted = Fd::AuditEntry.where(occurred_at: WINDOW.ago..)
        .where(actor_user_id: @holders).distinct.pluck(:actor_user_id)
      (@holders - acted).first(SHOWN)
    end
  end
end
