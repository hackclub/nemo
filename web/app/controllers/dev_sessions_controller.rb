class DevSessionsController < ApplicationController
  skip_before_action :require_staff
  before_action :only_in_development

  def create
    staff = Staff.find_or_initialize_by(user_id: params[:user_id])
    reset_session

    unless You::BaseController::MEMBER_ID.match?(staff.user_id)
      return redirect_to login_path, alert: "#{staff.user_id} is not a slack id"
    end

    session[:user_id] = staff.user_id

    if staff.role.nil?
      redirect_to you_api_path, notice: "signed in as #{staff.user_id}, no role"
    else
      redirect_to fd_root_path, notice: "signed in as #{staff.user_id}, #{staff.role}"
    end
  end

  private

  def only_in_development
    head :not_found unless Rails.env.development?
  end
end
