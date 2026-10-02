class AccountsController < ApplicationController
  WINDOW = 30.days
  DEEDS_SHOWN = 10

  def show
    @account = Fd::StaffSlack.find_by(staff_user_id: current_account.user_id)
    @linkable = Slack::Oauth.configured? && current_account.may?("slack.link")
    @roles = Authz.roles_held(current_account.user_id)
    @holding = @roles.any? || Authz.held(current_account.user_id).any?

    deeds = @holding ? Fd::Deeds.new(current_account.user_id, since: WINDOW.ago).rows : []
    @deed_count = deeds.size
    @deeds = deeds.first(DEEDS_SHOWN)

    @names = Fd::Names.for([current_account.user_id])
  end
end
