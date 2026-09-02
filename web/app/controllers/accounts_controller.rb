class AccountsController < ApplicationController
  WINDOW = 30.days
  DEEDS_SHOWN = 10
  ASK_SHOWN = 3

  def show
    @account = Fd::StaffSlack.find_by(staff_user_id: current_staff.user_id)
    @linkable = Slack::Oauth.configured?
    @held = held_families
    @holding = @held.any? { |_family, role| role.present? }
    @open_to_all = Channels::Audience.open_to_all.count unless @holding
    @ask = who_can_grant unless @holding
    @deeds = Fd::Deeds.new(current_staff.user_id, since: WINDOW.ago).rows.first(DEEDS_SHOWN)
    @names = Fd::Names.for([current_staff.user_id] + Array(@ask))
  end

  private

  def held_families
    fd = current_staff.manager? ? Fd::Access::MANAGER_ROLE : current_staff.role
    [["Fire Department", fd]] +
      Community::Permission.families.map { |family|
        [Community::Permission.family_label(family), community_role(family)]
      }
  end

  def who_can_grant
    managers = Staff.where(community_manager: true).pluck(:user_id)
    curators = Community::Grant.live.of_family("read")
      .where(role: Community::Permission.superadmin("read")).pluck(:user_id)
    (managers | curators).reject { |id| id == current_staff.user_id }.first(ASK_SHOWN)
  end
end
