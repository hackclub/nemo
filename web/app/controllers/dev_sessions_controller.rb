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
    said = [staff.manager? ? Fd::Access::MANAGER_ROLE : staff.role,
            *Community::Access.held(staff).values].compact
    said.empty? ? "holding nothing" : said.map { |role| role.tr("_", " ") }.to_sentence
  end

  def only_in_development
    head :not_found unless Rails.env.development?
  end
end
