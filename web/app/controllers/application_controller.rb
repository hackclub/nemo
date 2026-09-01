class ApplicationController < ActionController::Base
  allow_browser versions: :modern
  stale_when_importmap_changes

  before_action :require_staff

  helper_method :current_staff, :current_profile, :page_section

  private

  def page_section
    controller_path.start_with?("fd/") ? "fd" : "mn"
  end

  def needs(key)
    return if Fd::Flag.on?(key)

    redirect_to still_on, alert: "#{Fd::Flag.label(key).downcase} is turned off"
  end

  def still_on
    return fd_cases_path if Fd::Flag.on?(:fire_engine)
    return root_path if Fd::Flag.on?(:analytics)

    fd_settings_path
  end

  def current_staff
    return nil unless session[:user_id]

    @current_staff ||= Staff.find_or_initialize_by(user_id: session[:user_id])
  end

  def current_profile
    return nil unless current_staff

    @current_profile ||= CachetClient.profile(current_staff.user_id)
  end

  def require_staff
    return if current_staff.present?
    return head :unauthorized if request.format.json?

    redirect_to login_path, alert: "sign in to continue"
  end

  def community_role(family)
    Community::Access.role(current_staff, family)
  end
  helper_method :community_role

  def may_community?(key, record = nil)
    Community::Access.allow?(current_staff, key, record)
  end
  helper_method :may_community?

  def require_reading
    return if may_community?("analytics.workspace.read")

    refuse_community("analytics.workspace.read")
  end

  def require_operating
    return if may_community?("ops.engine.read")

    refuse_community("ops.engine.read")
  end

  def refuse_community(key)
    return head :forbidden if request.format.json?

    redirect_to root_path, alert: Community::Access.why_not(current_staff, key)
  end
end
