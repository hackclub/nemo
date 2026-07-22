class ChannelsController < ApplicationController
  before_action :require_community_manager

  SORT_COLUMNS = {
    "name" => ->(channel, engagement) { channel.name.to_s },
    "visibility" => ->(channel, engagement) { channel.visibility.to_s },
    "members" => ->(channel, engagement) { channel.total_members || 0 },
    "messages" => ->(channel, engagement) { engagement&.messages_tracked || 0 },
    "views" => ->(channel, engagement) { engagement&.total_views || 0 },
    "reactions" => ->(channel, engagement) { engagement&.total_reactions || 0 }
  }.freeze

  def index
    @engagement = Analytics::MartChannelEngagement.all.index_by(&:channel_id)
    @channels = Analytics::DimChannel.where(archived: false).to_a

    @sort = SORT_COLUMNS.key?(params[:sort]) ? params[:sort] : "name"
    @direction = params[:direction] == "desc" ? "desc" : "asc"
    @channels.sort_by! { |channel| SORT_COLUMNS[@sort].call(channel, @engagement[channel.channel_id]) }
    @channels.reverse! if @direction == "desc"
  end

  def show
    @channel = Analytics::DimChannel.find(params[:id])
    @engagement = Analytics::MartChannelEngagement.find_by(channel_id: @channel.channel_id)
    @activity_trend = Analytics::MartChannelActivity.where(channel_id: @channel.channel_id).order(:window_start)
    @scorecard_rows = Analytics::MartChannelOnboardingScorecard.where(channel_id: @channel.channel_id).order(:post_month)
  end

  private

  def require_community_manager
    return if current_staff.community_manager?

    redirect_to fire_engine_root_path
  end
end
