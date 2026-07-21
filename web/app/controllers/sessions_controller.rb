class SessionsController < ApplicationController
  layout "auth"
  skip_before_action :require_staff

  def new
    redirect_to root_path if current_staff
  end

  def create
    auth = request.env["omniauth.auth"]
    slack_id = auth&.extra&.raw_info&.[]("slack_id")
    staff = slack_id.present? ? Staff.find_by(user_id: slack_id) : nil

    if staff
      session[:user_id] = staff.user_id
      redirect_to root_path, notice: "signed in"
    else
      redirect_to auth_failure_path(message: "not_on_allowlist")
    end
  end

  def failure
    @message = params[:message]
  end

  def destroy
    reset_session
    redirect_to login_path
  end
end
