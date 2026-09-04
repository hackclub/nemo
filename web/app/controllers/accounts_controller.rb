class AccountsController < ApplicationController
  WINDOW = 30.days
  DEEDS_SHOWN = 10
  ASK_SHOWN = 3

  def show
    @account = Fd::StaffSlack.find_by(staff_user_id: current_account.user_id)
    @linkable = Slack::Oauth.configured? && current_account.may?("slack.link")
    @roles = Authz.roles_held(current_account.user_id)
    @capabilities = Authz.held(current_account.user_id)
    @holding = @roles.any? || @capabilities.any?
    @open_to_all = Channels::Audience.open_to_all.count unless @holding
    @ask = who_can_grant unless @holding
    @deeds = @holding ? Fd::Deeds.new(current_account.user_id, since: WINDOW.ago)
      .rows.first(DEEDS_SHOWN) : []
    @panels = Panel.visible_to(current_account)
    @my_channels = Channels::Audience::Grant.live
      .where(user_id: current_account.user_id).pluck(:channel_id)
    @names = Fd::Names.for([current_account.user_id] + Array(@ask))
  end

  private

  def who_can_grant
    Authz.who_holds("access.grant")
      .reject { |id| id == current_account.user_id }.first(ASK_SHOWN)
  end
end
