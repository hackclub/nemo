class SessionsController < ApplicationController
  layout "auth"
  skip_before_action :require_staff

  def new
    if current_staff&.role.present?
      redirect_to root_path
    elsif session[:user_id].present?
      redirect_to you_api_path
    end
  end

  def create
    auth = request.env["omniauth.auth"]
    slack_id = auth&.extra&.raw_info&.[]("slack_id").to_s
    return refuse("no_slack_id") unless You::BaseController::MEMBER_ID.match?(slack_id)

    staff = Staff.find_or_initialize_by(user_id: slack_id)
    reset_session
    session[:user_id] = staff.user_id

    if staff.role.present?
      flash[:said] = "Everything you do from here is recorded against #{staff.user_id}."
      redirect_to root_path, notice: "Signed in as a #{staff.role.tr('_', ' ')}"
    else
      redirect_to you_api_path, notice: "Signed in as #{staff.user_id}"
    end
  end

  def failure
    @message = params[:message]
    flash.clear
  end

  def destroy
    reset_session
    redirect_to login_path
  end

  private

  def refuse(message)
    reset_session
    redirect_to auth_failure_path(message: message)
  end
end
