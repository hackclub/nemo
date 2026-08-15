class DevSessionsController < ApplicationController
  skip_before_action :require_staff
  before_action :only_in_development

  def create
    staff = Staff.find_or_initialize_by(user_id: params[:user_id])
    reset_session

    if staff.role.nil?
      redirect_to login_path, alert: "#{staff.user_id} is not allowlisted"
    else
      session[:user_id] = staff.user_id
      redirect_to fd_root_path, notice: "signed in as #{staff.user_id}, #{staff.role}"
    end
  end

  private

  def only_in_development
    head :not_found unless Rails.env.development?
  end
end
