module Admin
  class PeopleController < BaseController
    WINDOW = 30.days
    FAMILIES = %w[fd read ops].freeze
    BANDS = [
      ["Can hand access out", :grants],
      ["Can act", :acts],
      ["Can only read", :reads]
    ].freeze

    def index
      @family = FAMILIES.include?(params[:family]) ? params[:family] : nil
      @term = params[:q].to_s.strip
      @grants = Fd::AccessGrant.live.newest_first.to_a
      @community = Community::Grant.live.to_a.group_by(&:user_id)
      @managers = Staff.where(community_manager: true).pluck(:user_id)
      @people = (@grants.map(&:user_id) + @community.keys + @managers).uniq
      @names = Fd::Names.for(@people)
      @acted = Fd::AuditEntry.where(occurred_at: WINDOW.ago..)
        .where(actor_user_id: @people).group(:actor_user_id).count
      @busiest = @acted.values.max || 0
      @bands = band(narrow(@people))
    end

    def search
      found = PeopleSearch.call(params[:q]).map do |row|
        { id: row.id, name: row.name, handle: row.handle,
          initial: row.initial, deleted: row.deleted }
      end
      render json: { members: found }
    end

    def show
      @user_id = params[:user_id]
      @fd = Fd::AccessGrant.live.for_person(@user_id).first
      @community = Community::Grant.live.for_person(@user_id).to_a
      @past = Community::Grant.ended.for_person(@user_id).newest_first.to_a +
        Fd::AccessGrant.ended.for_person(@user_id).newest_first.to_a
      @implied = Staff.find_by(user_id: @user_id)&.community_manager? || false
      @names = Fd::Names.for([@user_id, @fd&.granted_by] +
        (@community + @past).map(&:granted_by))
      @deeds = Fd::Deeds.new(@user_id, since: WINDOW.ago).rows.first(20)
      @held_since = ([@fd] + @community).compact.filter_map(&:granted_at).min
      @last_acted = @deeds.first&.at
      @identity_reads = AccessLog.where(actor_id: @user_id, field_class: "identity")
        .where(looked_at: WINDOW.ago..).count
      @channels_named = Channels::Audience::Grant.live.where(user_id: @user_id).count
    end

    private

    def narrow(people)
      kept = people
      kept = kept.select { |id| holds?(id, @family) } if @family
      kept = kept.select { |id| matches?(id) } if @term.present?
      kept.sort_by { |id| @names[id].to_s.downcase }
    end

    def matches?(user_id)
      needle = @term.downcase
      user_id.downcase.include?(needle) || @names[user_id].to_s.downcase.include?(needle)
    end

    def holds?(user_id, family)
      return fd_role(user_id).present? if family == "fd"

      held(user_id)[family].present?
    end

    def band(people)
      grouped = people.group_by { |id| rung(id) }
      BANDS.filter_map { |label, key|
        rows = grouped[key]
        [label, rows] if rows.present?
      }
    end

    def rung(user_id)
      return :grants if manager?(user_id)
      return :grants if held(user_id)["read"] == Community::Permission.superadmin("read")
      return :acts if held(user_id)["ops"].present? || fd_role(user_id).present?

      :reads
    end

    def manager?(user_id)
      @managers.include?(user_id)
    end

    def fd_role(user_id)
      return @fd&.role if @grants.nil?

      @grants.find { |grant| grant.user_id == user_id }&.role
    end
    helper_method :fd_role

    def held(user_id)
      (@community[user_id] || []).to_h { |grant| [grant.family, grant.role] }
    end
    helper_method :held
  end
end
