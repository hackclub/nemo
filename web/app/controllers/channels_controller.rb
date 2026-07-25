class ChannelsController < ApplicationController
  before_action :require_community_manager

  PER_PAGE = 100

  SORT_SQL = {
    "name" => "dim_channel.name",
    "visibility" => "dim_channel.visibility",
    "members" => "dim_channel.total_members",
    "messages" => "e.messages_tracked",
    "views" => "e.total_views",
    "reactions" => "e.total_reactions"
  }.freeze

  def index
    @q = params[:q].to_s.strip
    @page = [params[:page].to_i, 0].max
    @sort = SORT_SQL.key?(params[:sort]) ? params[:sort] : "name"
    @direction = params[:direction] == "asc" ? "asc" : "desc"

    base = Analytics::DimChannel.where(archived: false)
    base = base.where("dim_channel.name ILIKE ?", "%#{@q}%") if @q.present?
    total = base.count

    @channels = base
      .joins("LEFT JOIN analytics.mart_channel_engagement e ON e.channel_id = #{Analytics::DimChannel.table_name}.channel_id")
      .order(Arel.sql(order_clause))
      .limit(PER_PAGE)
      .offset(@page * PER_PAGE)
      .to_a
    @has_more = (@page + 1) * PER_PAGE < total
    @engagement = Analytics::MartChannelEngagement
      .where(channel_id: @channels.map(&:channel_id)).index_by(&:channel_id)

    return unless request.headers["X-Requested-With"] == "channel-list"

    response.set_header("X-Has-More", @has_more.to_s)
    render partial: "rows", locals: { channels: @channels, engagement: @engagement }, layout: false
  end

  def show
    @channel = Analytics::DimChannel.find(params[:id])
    @engagement = Analytics::MartChannelEngagement.find_by(channel_id: @channel.channel_id)
    @activity_trend = Analytics::MartChannelActivity.where(channel_id: @channel.channel_id).order(:window_start)
    @scorecard_rows = Analytics::MartChannelOnboardingScorecard.where(channel_id: @channel.channel_id).order(:post_month)

    @end_date = parse_range_date(params[:end]) || (Date.current - 1)
    @start_date = parse_range_date(params[:start]) || (@end_date - 30)
    @range = ChannelAnalyticsService.fetch(
      channel_id: @channel.channel_id, name: @channel.name,
      start_date: @start_date, end_date: @end_date, privacy: @channel.visibility
    )
  end

  private

  def parse_range_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def order_clause
    metric = "#{SORT_SQL[@sort]} #{@direction} NULLS LAST"
    return metric if @q.blank?

    ql = @q.downcase
    rank = ActiveRecord::Base.sanitize_sql_array(
      ["CASE WHEN lower(dim_channel.name) = ? THEN 0 WHEN lower(dim_channel.name) LIKE ? THEN 1 ELSE 2 END", ql, "#{ql}%"]
    )
    "#{rank}, #{metric}"
  end

  def require_community_manager
    return if current_staff.community_manager?

    redirect_to fire_engine_root_path
  end
end
