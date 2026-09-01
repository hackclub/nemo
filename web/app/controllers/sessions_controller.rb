class SessionsController < ApplicationController
  layout "auth"
  skip_before_action :require_staff

  def new
    redirect_to root_path if current_staff.present?
  end

  def create
    auth = request.env["omniauth.auth"]
    slack_id = auth&.extra&.raw_info&.[]("slack_id")

    if slack_id.blank?
      reset_session
      return redirect_to auth_failure_path(message: "not_allowlisted")
    end

    staff = Staff.find_or_create_by!(user_id: slack_id)
    reset_session
    session[:user_id] = staff.user_id
    flash[:said] = "Everything you do from here is recorded against #{staff.user_id}."
    redirect_to root_path, notice: welcome(staff)
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

  def welcome(staff)
    held = [staff.role, *Community::Access.held(staff).values].compact
    return "Signed in" if held.empty?

    "Signed in as #{held.map { |role| role.tr('_', ' ') }.to_sentence}"
  end
end
