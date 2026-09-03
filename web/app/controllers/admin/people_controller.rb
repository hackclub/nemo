module Admin
  class PeopleController < BaseController
    WINDOW = 30.days
    BANDS = [
      ["Can hand access out", :grants],
      ["Holds a role", :role],
      ["Extra scopes only", :scopes]
    ].freeze

    def index
      @role = Authz.role_names.include?(params[:role]) ? params[:role] : nil
      @term = params[:q].to_s.strip
      @people = everyone
      @names = Fd::Names.for(@people)
      @roles_of = roles_of(@people)
      @extras_of = extras_of(@people)
      @granters = granters(@people)
      @acted = Fd::AuditEntry.where(occurred_at: WINDOW.ago..)
        .where(actor_user_id: @people).group(:actor_user_id).count
      @busiest = @acted.values.max || 0
      @bands = band(narrow(@people))
      @moved = Authz.keys.select { |key| Authz::Override.moved?(key) }
      @dark = Fd::Flag::KEYS.reject { |key| Fd::Flag.on?(key) }
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
      @history = Authz::Grant.for_person(@user_id).newest_first.to_a
      @names = Fd::Names.for([@user_id] + @history.map(&:granted_by) +
        Channels::Audience::Grant.live.where(user_id: @user_id).pluck(:granted_by))
      @deeds = Fd::Deeds.new(@user_id, since: WINDOW.ago).rows.first(20)
      @held_since = @history.filter_map(&:granted_at).min
      @last_acted = @deeds.first&.at
      @identity_reads = AccessLog.where(actor_id: @user_id, field_class: "identity")
        .where(looked_at: WINDOW.ago..).count
      @channels_named = Channels::Audience::Grant.live.where(user_id: @user_id).count
      load_capabilities
    end

    private

    def load_capabilities
      @account = Account.find_by(user_id: @user_id) || Account.new(user_id: @user_id)
      @roles = Authz.roles_held(@user_id)
      @effective = Authz.held(@user_id)
      @baseline = @roles.flat_map { |role| Authz.baseline(role) }.uniq
      @deviations = Authz::Grant.live.for_person(@user_id).capabilities
        .pluck(:name, :effect).to_h
      @added_scopes = @deviations.select { |_key, effect| effect == "allow" }.keys
      @channel_rows = Channels::Audience::Grant.live.where(user_id: @user_id).to_a
      @role_channels = @roles.index_with { |role|
        Channels::Audience::Grant.live.where(role: role).pluck(:channel_id)
      }
      named = (@channel_rows.map(&:channel_id) + @role_channels.values.flatten).uniq
      @channel_names = Analytics::DimChannel.where(channel_id: named).index_by(&:channel_id)
      @grant_rows = Authz::Grant.for_person(@user_id).newest_first.to_a
    end

    # inherited from the role, added by hand, taken away by hand, or simply off
    def standing(key)
      effect = @deviations[key]
      return :added if effect == "allow"
      return :removed if effect == "deny"
      return :inherited if @effective.key?(key)

      :off
    end
    helper_method :standing

    # anyone the new model knows, plus whoever is still only in the old tables
    def everyone
      (Authz::Grant.live.pluck(:user_id) +
        Channels::Audience::Grant.live.where.not(user_id: nil)
          .pluck(:user_id)).compact.uniq
    end

    ROLES_OF = "SELECT user_id, role FROM app.effective_role " \
               "WHERE user_id = ANY(ARRAY[?]::text[])".freeze

    GRANTERS = "SELECT DISTINCT user_id FROM app.effective_capability " \
               "WHERE capability = 'access.grant' AND user_id = ANY(ARRAY[?]::text[])".freeze

    def roles_of(people)
      return {} if people.empty?

      ask(ROLES_OF, people).group_by(&:first).transform_values { |group|
        group.map(&:last).sort
      }
    end

    def granters(people)
      return Set.new if people.empty?

      ask(GRANTERS, people).flatten.to_set
    end

    def ask(sql, people)
      ApplicationRecord.connection.select_rows(ApplicationRecord.sanitize_sql([sql, people]))
    end

    def extras_of(people)
      return {} if people.empty?

      Authz::Grant.live.capabilities.where(effect: "allow", user_id: people)
        .group(:user_id).count
    end

    def narrow(people)
      kept = people
      kept = kept.select { |id| (@roles_of[id] || []).include?(@role) } if @role
      kept = kept.select { |id| matches?(id) } if @term.present?
      kept.sort_by { |id| @names[id].to_s.downcase }
    end

    def matches?(user_id)
      needle = @term.downcase
      user_id.downcase.include?(needle) || @names[user_id].to_s.downcase.include?(needle)
    end

    def band(people)
      grouped = people.group_by { |id| rung(id) }
      BANDS.filter_map { |label, key|
        rows = grouped[key]
        [label, rows] if rows.present?
      }
    end

    def rung(user_id)
      return :grants if @granters.include?(user_id)
      return :role if (@roles_of[user_id] || []).any?

      :scopes
    end
  end
end
