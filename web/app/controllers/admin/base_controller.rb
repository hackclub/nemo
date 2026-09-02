module Admin
  class BaseController < ApplicationController
    before_action :require_admin

    private

    def require_admin
      return if Fd::Access.manager?(current_staff)

      redirect_to root_path, alert: "the admin section is community managers only"
    end

    def may_grant?
      Fd::Access.manager?(current_staff)
    end
    helper_method :may_grant?

    def audit(record, verb, **options)
      Fd::Audit.record(record, verb, actor: current_staff.user_id,
        request_id: request.request_id, **options)
    end
  end
end
