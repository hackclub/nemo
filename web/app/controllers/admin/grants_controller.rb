module Admin
  class GrantsController < BaseController
    def create
      user_id = asked_for
      return refuse("search for somebody, or paste their Slack user id") if user_id.blank?
      return refuse("#{user_id} is not a Slack user id") unless user_id.match?(PeopleSearch::MEMBER_ID)
      return refuse(Community::Access.why_not(current_account, "analytics.grant")) unless may_grant?
      return refuse("somebody else has to take yours back") if dropping_myself?(user_id)

      changed = ActiveRecord::Base.transaction { settle_capability_model(user_id) }
      return redirect_to(admin_person_path(user_id), notice: "nothing changed") if changed.zero?

      redirect_to admin_person_path(user_id), notice: "#{changed} change(s) saved"
    rescue Authz::Grant::NotAllowed => e
      refuse(e.message)
    end

    def destroy
      return refuse(Community::Access.why_not(current_account, "analytics.grant")) unless may_grant?

      user_id = params[:id].to_s.strip.upcase
      return refuse("#{user_id} is not a Slack user id") unless user_id.match?(PeopleSearch::MEMBER_ID)
      return refuse("somebody else has to take yours back") if user_id == current_account.user_id

      ActiveRecord::Base.transaction { take_it_all_back(user_id) }
      redirect_to admin_people_path, notice: "access taken back"
    end

    private

    def dropping_myself?(user_id)
      return false unless user_id == current_account.user_id
      return false unless Fd::Access.manager?(current_account)

      params[:role].to_s != Fd::Access::MANAGER_ROLE
    end

    def settle_capability_model(user_id)
      Account.find_or_create_by!(user_id: user_id)
      changed = give_role(user_id) + give_scopes(user_id) + name_channels(user_id)
      Current.forget_roles
      changed
    end

    def take_it_all_back(user_id)
      Authz::Grant.live.for_person(user_id).find_each do |row|
        row.take_back!(by: current_account.user_id)
        audit(row, "revoked", after: { "user_id" => user_id, row.kind => row.name })
      end
      Channels::Audience::Grant.live.where(user_id: user_id).find_each do |row|
        row.update!(revoked_by: current_account.user_id, revoked_at: Time.current)
      end
      Current.forget_roles
    end

    def new_model_holds?(user_id, asked)
      Authz::Grant.live.for_person(user_id).roles.pluck(:name) == [asked]
    end

    def settled_role?(user_id, asked)
      return Authz.roles_held(user_id).empty? if asked.blank?

      new_model_holds?(user_id, asked)
    end

    def give_role(user_id)
      asked = params[:role].to_s
      return 0 if settled_role?(user_id, asked)

      if asked.present?
        Authz::Grant.give!(user_id, kind: "role", name: asked,
          by: current_account.user_id, reason: params[:reason].presence)
        audit_grant(user_id, "role", asked, "granted")
      else
        Authz::Grant.live.for_person(user_id).roles.find_each do |row|
          row.take_back!(by: current_account.user_id)
          audit_grant(user_id, "role", row.name, "revoked")
        end
      end
      1
    end

    def give_scopes(user_id)
      wanted = Array(params[:scopes]).map(&:to_s).select { |key| Authz.keys.include?(key) }
      wanted.reject! { |key| Authz.locked?(key) }
      held = Authz::Grant.live.for_person(user_id).capabilities.where(effect: "allow")
        .pluck(:name)

      add_scopes(user_id, wanted - held) + drop_scopes(user_id, held - wanted)
    end

    def add_scopes(user_id, keys)
      keys.count do |key|
        Authz::Grant.give!(user_id, kind: "capability", name: key,
          by: current_account.user_id, reason: params[:reason].presence)
        audit_grant(user_id, "capability", key, "granted")
        true
      end
    end

    def drop_scopes(user_id, keys)
      return 0 if params[:scopes_settled].blank?

      Authz::Grant.live.for_person(user_id).capabilities.where(effect: "allow", name: keys)
        .count do |row|
          row.take_back!(by: current_account.user_id)
          audit(row, "revoked", after: { "user_id" => user_id, "capability" => row.name })
          true
        end
    end

    def name_channels(user_id)
      wanted = Array(params[:channels]).map(&:to_s).reject(&:blank?)
      known = Analytics::DimChannel.where(channel_id: wanted, archived: false).pluck(:channel_id)
      return 0 if known.empty?

      known.each do |channel_id|
        next if Channels::Audience::Grant.live
          .where(user_id: user_id, channel_id: channel_id).exists?

        Channels::Audience::Grant.create!(user_id: user_id, channel_id: channel_id,
          granted_by: current_account.user_id, granted_at: Time.current,
          reason: params[:reason].presence)
      end
      Admin::ChannelGrantsController.make_readable(user_id, by: current_account.user_id)
      known.size
    end

    def audit_grant(user_id, kind, name, verb)
      row = Authz::Grant.for_person(user_id).where(kind: kind, name: name).newest_first.first
      return if row.nil?

      audit(row, verb, after: { "user_id" => user_id, kind => name })
    end

    def asked_for
      [params[:user_id], params[:user_id_raw]]
        .map { |said| said.to_s.strip.delete_prefix("@").upcase }
        .find(&:present?)
        .to_s
    end

    def refuse(said)
      redirect_to admin_people_path, alert: said
    end
  end
end
