class ApplicationController < ActionController::Base
  allow_browser versions: :modern
  stale_when_importmap_changes

  before_action :require_account

  helper_method :current_account, :current_profile, :page_section

  private

  def page_section
    return "admin" if controller_path.start_with?("admin/")

    controller_path.start_with?("fd/") ? "fd" : "mn"
  end

  def needs(key)
    return if Fd::Flag.on?(key)

    redirect_to still_on, alert: "#{Fd::Flag.label(key).downcase} is turned off"
  end

  def still_on
    return fd_cases_path if Fd::Flag.on?(:fire_engine)
    return root_path if Fd::Flag.on?(:analytics)

    account_path
  end

  def current_account
    return nil unless session[:user_id]

    @current_account ||= Account.find_or_initialize_by(user_id: session[:user_id])
  end

  def current_profile
    return nil unless current_account

    @current_profile ||= CachetClient.profile(current_account.user_id)
  end

  def require_account
    return if current_account.present?
    return head :unauthorized if request.format.json?

    redirect_to login_path, alert: "sign in to continue"
  end

  def may_administer?
    Fd::Access.manager?(current_account)
  end
  helper_method :may_administer?

  def may_use_fire_engine?
    return false unless Fd::Flag.on?(:fire_engine)

    Fd::Access.manager?(current_account) || Authz.holds?(current_account, "case.read")
  end
  helper_method :may_use_fire_engine?

  def may_community?(key, record = nil)
    Community::Access.allow?(current_account, key, record)
  end
  helper_method :may_community?

  def visible_panel?(key)
    Panel.visible?(key, current_account)
  end
  helper_method :visible_panel?

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

    redirect_to root_path, alert: Community::Access.why_not(current_account, key)
  end
end
