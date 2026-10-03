class AccountsController < ApplicationController
  WINDOW = 30.days
  AUDIT_ROWS_SHOWN = 10

  def show
    @account = Fd::StaffSlack.find_by(staff_user_id: current_account.user_id)
    @linkable = Slack::Oauth.configured? && current_account.may?("slack.link")
    @roles = Authz.roles_held(current_account.user_id)
    @holding = @roles.any? || Authz.held(current_account.user_id).any?

    audit_rows = @holding ? Fd::AuditTrail.new(current_account.user_id, since: WINDOW.ago).rows : []
    @audit_row_count = audit_rows.size
    @audit_rows = audit_rows.first(AUDIT_ROWS_SHOWN)

    @names = Fd::Names.for([current_account.user_id])
  end
end
