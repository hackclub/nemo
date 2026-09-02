module Admin
  class GrantsController < BaseController
    def create
      user_id = asked_for
      return refuse("search for somebody, or paste their Slack user id") if user_id.blank?
      return refuse("#{user_id} is not a Slack user id") unless user_id.match?(PeopleSearch::MEMBER_ID)
      return refuse(Community::Access.why_not(current_staff, "analytics.grant")) unless may_grant?

      changed = settle(user_id)
      return redirect_to(admin_person_path(user_id), notice: "nothing changed") if changed.zero?

      redirect_to admin_person_path(user_id), notice: "#{changed} change(s) saved"
    rescue Fd::AccessGrant::NotAllowed, Community::Grant::NotAllowed => e
      refuse(e.message)
    end

    def destroy
      return refuse(Community::Access.why_not(current_staff, "analytics.grant")) unless may_grant?

      user_id = params[:id]
      wanted = params[:family].presence
      return refuse("#{wanted} is not a family") if wanted && !families.include?(wanted)

      (wanted ? [wanted] : families).each do |family|
        Community::Grant.take_back!(user_id, family: family, by: current_staff.user_id)
      end
      take_back_everything(user_id) if wanted.nil?
      redirect_to admin_people_path, notice: taken_back(wanted)
    end

    private

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
        Fd::AccessGrant.give!(user_id, role: asked, by: current_staff.user_id,
          reason: params[:reason])
        return count + 1
      end

      count + revoke_fd(user_id)
    end

    def settle_family(user_id, family)
      asked = params[:"#{family}_role"].to_s
      return 0 if asked == Community::Grant.role_for(user_id, family).to_s

      if asked.present?
        Community::Grant.give!(user_id, role: asked, by: current_staff.user_id,
          reason: params[:reason])
      else
        Community::Grant.take_back!(user_id, family: family, by: current_staff.user_id)
      end
      1
    end

    def held_fd(user_id)
      return Fd::Access::MANAGER_ROLE if Staff.find_by(user_id: user_id)&.community_manager?

      Fd::AccessGrant.role_for(user_id).to_s
    end

    def drop_manager(user_id)
      staff = Staff.find_by(user_id: user_id)
      return 0 unless staff&.community_manager?

      staff.update!(community_manager: false)
      1
    end

    def revoke_fd(user_id)
      live = Fd::AccessGrant.live.for_person(user_id).to_a
      live.each { |held| held.take_back!(by: current_staff.user_id) }
      live.size
    end

    def take_back_everything(user_id)
      Staff.where(user_id: user_id).update_all(community_manager: false)
      Fd::AccessGrant.live.for_person(user_id)
        .find_each { |held| held.take_back!(by: current_staff.user_id) }
    end

    def make_manager(user_id)
      staff = Staff.find_or_create_by!(user_id: user_id)
      staff.update!(community_manager: true)
      revoke_fd(user_id)
      true
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
