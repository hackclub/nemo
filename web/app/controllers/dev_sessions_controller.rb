class DevSessionsController < ApplicationController
  skip_before_action :require_staff
  before_action :only_in_development

  def create
    staff = Staff.find_or_create_by!(user_id: params[:user_id])
    reset_session
    session[:user_id] = staff.user_id
    redirect_to root_path, notice: "signed in as #{staff.user_id}, #{held(staff)}"
  end

  private

  def held(staff)
    roles = Authz.roles_held(staff.user_id).map { |role| Authz.role_label(role) }
    extras = Authz::Grant.live.for_person(staff.user_id).capabilities
      .where(effect: "allow").count
    return "holding nothing" if roles.empty? && extras.zero?

    said = roles.any? ? roles.to_sentence : "no role"
    return said if extras.zero?

    "#{said}, #{extras} #{'extra scope'.pluralize(extras)}"
  end

  def only_in_development
    head :not_found unless Rails.env.development?
  end
end
