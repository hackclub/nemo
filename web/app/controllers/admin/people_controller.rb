module Admin
  class PeopleController < BaseController
    WINDOW = 30.days
    BANDS = [
      ["Can grant access", :grants],
      ["Has role", :role],
      ["Extra scopes only", :scopes]
    ].freeze

    def index
      @role = Authz.role_names.include?(params[:role]) ? params[:role] : nil
      @term = params[:q].to_s.strip
      @people = granted_user_ids
      @names = Fd::Names.for(@people)
      @roles_of = roles_of(@people)
      @extras_of = extras_of(@people)
      @access_granters = access_granters(@people)
      @action_counts = Fd::AuditEntry.where(occurred_at: WINDOW.ago..)
        .where(actor_user_id: @people).group(:actor_user_id).count
      @peak_actions = @action_counts.values.max || 0
      @bands = group_by_grant_source(filter_user_ids(@people))
      @overridden_keys = Authz.keys.select { |key| Authz::Override.changed?(key) }
      @disabled_flags = Fd::Flag::KEYS.reject { |key| Fd::Flag.on?(key) }
    end

    def search
      members = PeopleSearch.call(params[:q]).map do |row|
        { id: row.id, name: row.name, handle: row.handle,
          initial: row.initial, deleted: row.deleted }
      end
      render json: { members: members }
    end

    def show
      @user_id = params[:user_id]
      @history = Authz::Grant.for_person(@user_id).newest_first.to_a
      @names = Fd::Names.for([@user_id] + @history.map(&:granted_by) +
        Channels::Audience::Grant.live.where(user_id: @user_id).pluck(:granted_by))
      @audit_rows = Fd::AuditTrail.new(@user_id, since: WINDOW.ago).rows.first(20)
      @access_since = @history.filter_map(&:granted_at).min
      @last_action_at = @audit_rows.first&.at
      @identity_reads = AccessLog.where(actor_id: @user_id, field_class: "identity")
        .where(looked_at: WINDOW.ago..).count
      @channels_named = Channels::Audience::Grant.live.where(user_id: @user_id).count
      load_capabilities
    end

    private

    def load_capabilities
      @account = Account.find_by(user_id: @user_id) || Account.new(user_id: @user_id)
      @roles = Authz.effective_roles(@user_id)
      @effective = Authz.effective_capabilities(@user_id)
      @baseline = @roles.flat_map { |role| Authz.baseline(role) }.uniq
      @deviations = Authz::Grant.live.for_person(@user_id).capabilities
        .pluck(:name, :effect).to_h
      @added_scopes = @deviations.select { |_key, effect| effect == "allow" }.keys
      @channel_rows = Channels::Audience::Grant.live.where(user_id: @user_id).to_a
      @role_channels = @roles.index_with { |role|
        Channels::Audience::Grant.live.where(role: role).pluck(:channel_id)
      }
      @appointments = ::Prometheus::Appointment.for_person(@user_id).order(:channel_id).to_a
      channel_ids = (@channel_rows.map(&:channel_id) + @role_channels.values.flatten +
        @appointments.map(&:channel_id)).uniq
      @channel_names = Analytics::DimChannel.where(channel_id: channel_ids).index_by(&:channel_id)
      @grant_rows = Authz::Grant.for_person(@user_id).newest_first.to_a
    end

    def standing(key)
      effect = @deviations[key]
      return :added if effect == "allow"
      return :removed if effect == "deny"
      return :inherited if @effective.key?(key)

      :off
    end
    helper_method :standing

    def granted_user_ids
      (Authz::Grant.live.pluck(:user_id) +
        Channels::Audience::Grant.live.where.not(user_id: nil).pluck(:user_id) +
        ::Prometheus::Appointment.distinct.pluck(:user_id)).compact.uniq
    end

    ROLES_OF = "SELECT user_id, role FROM app.effective_role " \
               "WHERE user_id = ANY(ARRAY[?]::text[])".freeze

    ACCESS_GRANTERS_SQL = "SELECT DISTINCT user_id FROM app.effective_capability " \
               "WHERE capability = 'access.grant' AND user_id = ANY(ARRAY[?]::text[])".freeze

    def roles_of(user_ids)
      return {} if user_ids.empty?

      query_rows(ROLES_OF, user_ids).group_by(&:first).transform_values { |group|
        group.map(&:last).sort
      }
    end

    def access_granters(user_ids)
      return Set.new if user_ids.empty?

      query_rows(ACCESS_GRANTERS_SQL, user_ids).flatten.to_set
    end

    def query_rows(sql, user_ids)
      ApplicationRecord.connection.select_rows(ApplicationRecord.sanitize_sql([sql, user_ids]))
    end

    def extras_of(user_ids)
      return {} if user_ids.empty?

      Authz::Grant.live.capabilities.where(effect: "allow", user_id: user_ids)
        .group(:user_id).count
    end

    def filter_user_ids(user_ids)
      filtered = user_ids
      filtered = filtered.select { |id| (@roles_of[id] || []).include?(@role) } if @role
      filtered = filtered.select { |id| matches?(id) } if @term.present?
      filtered.sort_by { |id| @names[id].to_s.downcase }
    end

    def matches?(user_id)
      needle = @term.downcase
      user_id.downcase.include?(needle) || @names[user_id].to_s.downcase.include?(needle)
    end

    def group_by_grant_source(user_ids)
      grouped = user_ids.group_by { |id| grant_source(id) }
      BANDS.filter_map { |label, key|
        rows = grouped[key]
        [label, rows] if rows.present?
      }
    end

    def grant_source(user_id)
      return :grants if @access_granters.include?(user_id)
      return :role if (@roles_of[user_id] || []).any?

      :scopes
    end
  end
end
