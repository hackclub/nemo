class ApplicationController < ActionController::Base
  allow_browser versions: :modern
  stale_when_importmap_changes

  before_action :require_staff

  helper_method :current_staff, :current_profile

  private

  def current_staff
    return nil unless session[:user_id]

    @current_staff ||= Staff.find_by(user_id: session[:user_id])
  end

  def current_profile
    return nil unless current_staff

    @current_profile ||= CachetClient.profile(current_staff.user_id)
  end

  def require_staff
    return if current_staff&.role.present?

    redirect_to login_path, alert: "sign in to continue"
  end
end
