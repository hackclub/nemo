class ChannelsController < ApplicationController
  before_action { needs(:analytics) }

  PER_PAGE = 100
  RANGE_PRESETS = [7, 28, 90].freeze
  DEFAULT_RANGE_DAYS = 28

  SORT_SQL = {
    "name" => "dim_channel.name",
    "members" => "r.total_members",
    "created" => "dim_channel.date_created",
    "messages" => "r.messages_posted_by_members",
    "posters" => "r.members_who_posted",
    "viewers" => "r.members_who_viewed"
  }.freeze

  SPOKE_SHARE = "r.members_who_posted::numeric / NULLIF(r.total_members, 0)".freeze

  FILTERS = {
    "spoke_over_10" => ["Who spoke", "over 10%", "#{SPOKE_SHARE} > 0.10"],
    "spoke_under_2" => ["Who spoke", "under 2%", "#{SPOKE_SHARE} < 0.02"],
    "members_over_10000" => ["Members", "over 10,000", "r.total_members > 10000"],
    "members_under_2000" => ["Members", "under 2,000", "r.total_members < 2000"]
  }.freeze

  QUIET_FLOOR = 25
  QUIET_LIMIT = 8

  RANGE_JOIN = "LEFT JOIN analytics.mart_channel_range r ON r.channel_id = dim_channel.channel_id".freeze
  RANGE_COLUMNS = "dim_channel.*, r.messages_posted_by_members AS range_messages, " \
                  "r.members_who_posted AS range_posters, r.total_members AS range_members, " \
                  "r.members_who_viewed AS range_viewers".freeze

  def index
    @q = params[:q].to_s.strip
    @page = [params[:page].to_i, 0].max
    @sort = SORT_SQL.key?(params[:sort]) ? params[:sort] : "members"
    @direction = params[:direction] == "asc" ? "asc" : "desc"
    @view = params[:view] == "grid" ? "grid" : "table"
    @filters = Array(params[:f]).select { |key| FILTERS.key?(key) }.uniq

    scope = Analytics::DimChannel.where(archived: false).joins(RANGE_JOIN)
    scope = scope.where("dim_channel.name ILIKE ?", "%#{@q}%") if @q.present?
    @filters.each { |key| scope = scope.where(Arel.sql(FILTERS.fetch(key).last)) }

    @total = scope.count

    @channels = scope
      .select(RANGE_COLUMNS)
      .order(Arel.sql(order_clause))
      .limit(PER_PAGE)
      .offset(@page * PER_PAGE)
      .to_a
    @has_more = (@page + 1) * PER_PAGE < @total
    @pages = [(@total / PER_PAGE.to_f).ceil, 1].max

    @quiet_page = [params[:quiet_page].to_i, 1].max
    @quiet_total = quiet_scope.count
    @quiet_pages = [(@quiet_total / QUIET_LIMIT.to_f).ceil, 1].max
    @quiet_page = @quiet_page.clamp(1, @quiet_pages)
    @quiet_rooms = quiet_rooms
  end

  def show
    @channel = Analytics::DimChannel.find(params[:id])
    @activity_trend = Analytics::MartChannelActivity.where(channel_id: @channel.channel_id).order(:window_start)
    @scorecard_rows = Analytics::MartChannelOnboardingScorecard
      .where(channel_id: @channel.channel_id, newcomer_volume: HomeHelper::MIN_SAMPLE..)
      .order(:post_month)

    coverage = Slack::Analytics.coverage
    last_available = coverage ? Date.iso8601(coverage["end_date"]) : (Date.current - 2)
    custom_start = parse_range_date(params[:start])
    custom_end = parse_range_date(params[:end])

    if custom_start || custom_end
      @range_preset = nil
      @end_date = custom_end || last_available
      @start_date = custom_start || (@end_date - (DEFAULT_RANGE_DAYS - 1))
      @start_date = @end_date if @start_date > @end_date
    else
      @range_preset = RANGE_PRESETS.include?(params[:days].to_i) ? params[:days].to_i : DEFAULT_RANGE_DAYS
      @end_date = last_available
      @start_date = @end_date - (@range_preset - 1)
    end

    @range_max = last_available
    @range_min = [@channel.date_created&.to_date, last_available - 400].compact.max
    all_time_start = @channel.date_created&.to_date || (last_available - 400)
    @range, @all_time = Slack::Analytics.parallel(
      -> {
        Slack::Analytics.channel_activity(
          channel_id: @channel.channel_id, name: @channel.name,
          from: @start_date, to: @end_date, privacy: @channel.visibility
        )
      },
      -> {
        Slack::Analytics.channel_activity(
          channel_id: @channel.channel_id, name: @channel.name,
          from: all_time_start, to: last_available, privacy: @channel.visibility
        )
      }
    )
    @member_count = @all_time.stats&.dig("total_members_count")
  end

  private

  def quiet_scope
    Analytics::MartChannelRange
      .where(visibility: "public")
      .where("members_who_posted >= ?", QUIET_FLOOR)
      .where("members_who_viewed > members_who_posted")
  end

  def quiet_rooms
    quiet_scope
      .order(Arel.sql("members_who_viewed::numeric / members_who_posted DESC"))
      .limit(QUIET_LIMIT)
      .offset((@quiet_page - 1) * QUIET_LIMIT)
  end

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
end
