class HomeController < ApplicationController
  before_action :require_community_manager

  def index
    @activation = Analytics::MartActivation.take
    @participation = Analytics::MartParticipation.order(window_end: :desc).first
    @active_members = Analytics::DimMember.where(deactivated_at: nil).count
    @growth_months = Analytics::MartGrowth.order(month: :desc).limit(6).to_a.reverse
    @top_channels = Analytics::MartChannelActivity.order(messages_posted: :desc).limit(8)
    @activity_bands = Analytics::MartActivityDistribution.order(:band_order)
    @account_types = Analytics::MartAccountType.order(members: :desc)
  end

  private

  def require_community_manager
    return if current_staff.community_manager?

    redirect_to fire_engine_root_path
  end
end
