module Admin
  class GrantsController < BaseController
    def create
      user_id = asked_for
      return refuse("search for somebody, or paste their Slack user id") if user_id.blank?
      return refuse("#{user_id} is not a Slack user id") unless user_id.match?(PeopleSearch::MEMBER_ID)
      return refuse(Community::Access.why_not(current_staff, "analytics.grant")) unless may_grant?
      return refuse("somebody else has to take yours back") if dropping_myself?(user_id)

      changed = ActiveRecord::Base.transaction { settle_capability_model(user_id) }
      return redirect_to(admin_person_path(user_id), notice: "nothing changed") if changed.zero?

      redirect_to admin_person_path(user_id), notice: "#{changed} change(s) saved"
    rescue Fd::AccessGrant::NotAllowed, Community::Grant::NotAllowed => e
      refuse(e.message)
    end

    def destroy
      return refuse(Community::Access.why_not(current_staff, "analytics.grant")) unless may_grant?

      user_id = params[:id].to_s.strip.upcase
      wanted = params[:family].presence
      return refuse("#{user_id} is not a Slack user id") unless user_id.match?(PeopleSearch::MEMBER_ID)
      return refuse("#{wanted} is not a family") if wanted && !families.include?(wanted)
      return refuse("somebody else has to take yours back") if
        wanted.nil? && user_id == current_staff.user_id

      (wanted ? [wanted] : families).each do |family|
        take_back_family(user_id, family)
      end
      if wanted.nil?
        take_back_everything(user_id)
        Authz::Grant.live.for_person(user_id).find_each do |row|
          row.take_back!(by: current_staff.user_id)
          audit(row, "revoked", after: { "user_id" => user_id, row.kind => row.name })
        end
        Channels::Audience::Grant.live.where(user_id: user_id).find_each do |row|
          row.update!(revoked_by: current_staff.user_id, revoked_at: Time.current)
        end
        Current.forget_roles
      end
      redirect_to admin_people_path, notice: taken_back(wanted)
    end

    private

    def dropping_myself?(user_id)
      return false unless user_id == current_staff.user_id
      return false unless Fd::Access.manager?(current_staff)

      params[:role].to_s != Fd::Access::MANAGER_ROLE
    end

    # the old flag is a second source of manager, so a role change has to settle it too
    def settle_manager_flag(user_id, asked)
      staff = Staff.find_by(user_id: user_id)
      return if staff.nil?

      wanted = asked == Fd::Access::MANAGER_ROLE
      return if staff.community_manager? == wanted

      staff.update!(community_manager: wanted)
    end

    def settle_capability_model(user_id)
      Staff.find_or_create_by!(user_id: user_id)
      changed = give_role(user_id) + give_scopes(user_id) + name_channels(user_id) +
        clear_legacy(user_id)
      Current.forget_roles
      changed
    end

    # the resolver still reads the old tables, so a save has to migrate off them
    # before it clears them, or the person is left holding nothing
    def clear_legacy(user_id)
      asked = params[:role].to_s
      return 0 unless asked.blank? || new_model_holds?(user_id, asked)

      families.sum { |family| clear_family(user_id, family) } + revoke_fd(user_id)
    end

    def clear_family(user_id, family)
      Community::Grant.live.of_family(family).where(user_id: user_id).count do |held|
        held.take_back!(by: current_staff.user_id)
        audit(held, "revoked", before: { "user_id" => user_id, "role" => held.role }, after: nil)
        true
      end
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
      settle_manager_flag(user_id, asked)
      return 0 if settled_role?(user_id, asked)

      if asked.present?
        Authz::Grant.give!(user_id, kind: "role", name: asked,
          by: current_staff.user_id, reason: params[:reason].presence)
        audit_grant(user_id, "role", asked, "granted")
      else
        Authz::Grant.live.for_person(user_id).roles.find_each do |row|
          row.take_back!(by: current_staff.user_id)
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
          by: current_staff.user_id, reason: params[:reason].presence)
        audit_grant(user_id, "capability", key, "granted")
        true
      end
    end

    def drop_scopes(user_id, keys)
      return 0 if params[:scopes_settled].blank?

      Authz::Grant.live.for_person(user_id).capabilities.where(effect: "allow", name: keys)
        .count do |row|
          row.take_back!(by: current_staff.user_id)
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
          granted_by: current_staff.user_id, granted_at: Time.current,
          reason: params[:reason].presence)
      end
      Admin::ChannelGrantsController.make_readable(user_id, by: current_staff.user_id)
      known.size
    end

    def audit_grant(user_id, kind, name, verb)
      row = Authz::Grant.for_person(user_id).where(kind: kind, name: name).newest_first.first
      return if row.nil?

      audit(row, verb, after: { "user_id" => user_id, kind => name })
    end

    def settle(user_id)
      settle_fd(user_id) +
        Community::Permission.families.sum { |family| settle_family(user_id, family) }
    end

    def settle_fd(user_id)
      asked = params[:fd_role].to_s
      return 0 if asked == held_fd(user_id)

      count = drop_manager(user_id)
      return count + 1 if asked == Fd::Access::MANAGER_ROLE && make_manager(user_id)

      if asked.present?
        grant = Fd::AccessGrant.give!(user_id, role: asked, by: current_staff.user_id,
          reason: params[:reason])
        audit(grant, "granted",
          after: { "user_id" => user_id, "role" => asked, "reason" => grant.reason })
        return count + 1
      end

      count + revoke_fd(user_id)
    end

    def settle_family(user_id, family)
      asked = params[:"#{family}_role"].to_s
      return 0 if asked == Community::Grant.role_for(user_id, family).to_s

      if asked.present?
        grant = Community::Grant.give!(user_id, role: asked, by: current_staff.user_id,
          reason: params[:reason])
        audit(grant, "granted",
          after: { "user_id" => user_id, "role" => asked, "reason" => grant.reason })
      else
        take_back_family(user_id, family)
      end
      1
    end

    def take_back_family(user_id, family)
      Community::Grant.live.of_family(family).where(user_id: user_id).find_each do |held|
        held.take_back!(by: current_staff.user_id)
        audit(held, "revoked", before: { "user_id" => user_id, "role" => held.role }, after: nil)
      end
    end

    def held_fd(user_id)
      return Fd::Access::MANAGER_ROLE if Staff.find_by(user_id: user_id)&.community_manager?

      Fd::AccessGrant.role_for(user_id).to_s
    end

    def drop_manager(user_id)
      staff = Staff.find_by(user_id: user_id)
      return 0 unless staff&.community_manager?

      staff.update!(community_manager: false)
      note_manager(user_id, "revoked")
      1
    end

    def revoke_fd(user_id)
      live = Fd::AccessGrant.live.for_person(user_id).to_a
      live.each do |held|
        held.take_back!(by: current_staff.user_id)
        audit(held, "revoked", before: { "user_id" => user_id, "role" => held.role }, after: nil)
      end
      live.size
    end

    def take_back_everything(user_id)
      drop_manager(user_id)
      revoke_fd(user_id)
    end

    def make_manager(user_id)
      staff = Staff.find_or_create_by!(user_id: user_id)
      staff.update!(community_manager: true)
      revoke_fd(user_id)
      note_manager(user_id, "granted")
      true
    end

    def note_manager(user_id, verb)
      Fd::AuditEntry.create!(actor_user_id: current_staff.user_id, actor_kind: "human",
        entity_type: "grant", entity_id: 0, verb: verb,
        after: { "user_id" => user_id, "role" => Fd::Access::MANAGER_ROLE },
        source_app: Fd::Audit::SOURCE_APP, request_id: request.request_id)
    end

    def asked_for
      [params[:user_id], params[:user_id_raw]]
        .map { |said| said.to_s.strip.delete_prefix("@").upcase }
        .find(&:present?)
        .to_s
    end

    def families
      Community::Permission.families
    end

    def taken_back(family)
      return "community access taken back" if family.nil?

      "#{Community::Permission.family_label(family).downcase} taken back"
    end

    def refuse(said)
      redirect_to admin_people_path, alert: said
    end
  end
end
