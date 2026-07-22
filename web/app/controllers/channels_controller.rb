class ChannelsController < ApplicationController
  before_action :require_community_manager

  def index
    @channels = Analytics::DimChannel.where(archived: false).order(:name)
    @engagement = Analytics::MartChannelEngagement.all.index_by(&:channel_id)
  end

  def show
    @channel = Analytics::DimChannel.find(params[:id])
    @engagement = Analytics::MartChannelEngagement.find_by(channel_id: @channel.channel_id)
  end

  private

  def require_community_manager
    return if current_staff.community_manager?

    redirect_to fire_engine_root_path
  end
end
