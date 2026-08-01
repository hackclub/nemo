class ChannelsController < ApplicationController
  before_action :require_community_manager

  PER_PAGE = 100

  SORT_SQL = {
    "name" => "dim_channel.name",
    "members" => "dim_channel.total_members",
    "created" => "dim_channel.date_created"
  }.freeze

  def index
    @q = params[:q].to_s.strip
    @page = [params[:page].to_i, 0].max
    @sort = SORT_SQL.key?(params[:sort]) ? params[:sort] : "members"
    @direction = params[:direction] == "asc" ? "asc" : "desc"

    base = Analytics::DimChannel.where(archived: false)
    base = base.where("dim_channel.name ILIKE ?", "%#{@q}%") if @q.present?
    total = base.count

    @channels = base
      .order(Arel.sql(order_clause))
      .limit(PER_PAGE)
      .offset(@page * PER_PAGE)
      .to_a
    @has_more = (@page + 1) * PER_PAGE < total

    return unless request.headers["X-Requested-With"] == "channel-list"

    response.set_header("X-Has-More", @has_more.to_s)
    render partial: "rows", locals: { channels: @channels }, layout: false
  end

  def show
    @channel = Analytics::DimChannel.find(params[:id])
    @activity_trend = Analytics::MartChannelActivity.where(channel_id: @channel.channel_id).order(:window_start)
    @scorecard_rows = Analytics::MartChannelOnboardingScorecard.where(channel_id: @channel.channel_id).order(:post_month)

    coverage = Slack::Analytics.coverage
    last_available = coverage ? Date.iso8601(coverage["end_date"]) : (Date.current - 2)
    @end_date = parse_range_date(params[:end]) || last_available
    @start_date = parse_range_date(params[:start]) || (@end_date - 30)
    @range = Slack::Analytics.channel_activity(
      channel_id: @channel.channel_id, name: @channel.name,
      from: @start_date, to: @end_date, privacy: @channel.visibility
    )
    @all_time = Slack::Analytics.channel_activity(
      channel_id: @channel.channel_id, name: @channel.name,
      from: @channel.date_created&.to_date || (last_available - 400),
      to: last_available, privacy: @channel.visibility
    )
    @member_count = @all_time.stats&.dig("total_members_count")
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
