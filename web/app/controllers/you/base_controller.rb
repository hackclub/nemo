module You
  class BaseController < ApplicationController
    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    skip_before_action :require_staff
    before_action :require_a_member

    helper_method :member_id

    private

    def member_id
      session[:user_id].to_s
    end

    def require_a_member
      return if MEMBER_ID.match?(member_id)

      reset_session
      return head :unauthorized if request.format.json?

      redirect_to login_path, alert: "sign in to continue"
    end
  end
end
