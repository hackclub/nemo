module Fd
  class SettingsController < BaseController
    TABS = { "access" => "Access", "history" => "Grant history" }.freeze
    WINDOW = 30.days
    DORMANT_AFTER = 30.days

    def show
      @tab = TABS.key?(params[:tab]) ? params[:tab] : "access"
      @grants = AccessGrant.live.newest_first.to_a
      @history = AccessGrant.newest_first.limit(50).to_a if @tab == "history"
      @acted = acted_since(WINDOW.ago)
      @last_acted = last_acted
      @dormant = dormant
      @names = Names.for(named)
    end

    private

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
