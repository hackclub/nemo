class ChannelsController < ApplicationController
  before_action { needs(:analytics) }

  PER_PAGE = 50
  RANGE_PRESETS = [7, 28, 90].freeze
  DEFAULT_RANGE_DAYS = 28

  SORT_SQL = {
    "name" => "dim_channel.name",
    "members" => "r.total_members",
    "created" => "dim_channel.date_created",
    "messages" => "r.messages_posted_by_members",
    "posters" => "r.members_who_posted",
    "viewers" => "r.members_who_viewed",
    "quiet" => "r.last_message_at"
  }.freeze

  SPOKE_SHARE = "r.members_who_posted::numeric / NULLIF(r.total_members, 0)".freeze

  FILTERS = {
    "spoke_over_10" => ["Who spoke", "over 10%", "#{SPOKE_SHARE} > 0.10"],
    "spoke_under_2" => ["Who spoke", "under 2%", "#{SPOKE_SHARE} < 0.02"],
    "members_over_10000" => ["Members", "over 10,000", "r.total_members > 10000"],
    "members_under_2000" => ["Members", "under 2,000", "r.total_members < 2000"],
    "read_not_written" => ["Read", "but not written in",
                           "r.members_who_posted >= 25 " \
                           "AND r.members_who_viewed > r.members_who_posted"],
    "never_posted" => ["Last post", "never",
                       "r.channel_id IS NOT NULL AND r.last_message_at IS NULL"],
    "quiet_90d" => ["Last post", "over 90 days ago",
                    "r.last_message_at < now() - interval '90 days'"],
    "quiet_1y" => ["Last post", "over a year ago",
                   "r.last_message_at < now() - interval '365 days'"]
  }.freeze

  RANGE_JOIN = "LEFT JOIN analytics.mart_channel_range r ON r.channel_id = dim_channel.channel_id".freeze
  RANGE_COLUMNS = "dim_channel.*, r.messages_posted_by_members AS range_messages, " \
                  "r.members_who_posted AS range_posters, r.total_members AS range_members, " \
                  "r.members_who_viewed AS range_viewers, " \
                  "r.last_message_at AS range_last_post".freeze

  def index
    @q = params[:q].to_s.strip
    @page = [params[:page].to_i, 0].max
    @sort = SORT_SQL.key?(params[:sort]) ? params[:sort] : "members"
    @direction = params[:direction] == "asc" ? "asc" : "desc"
    @view = params[:view] == "grid" ? "grid" : "table"
    @scope_all = params[:scope] == "all"
    @filters = @scope_all ? [] : Array(params[:f]).select { |key| FILTERS.key?(key) }.uniq

    mine = Channels::Audience.for(current_staff)
    @mine_total = mine.count
    @all_total = Channels::Audience.everything.count
    @locked_total = @all_total - @mine_total

    scope = mine.joins(RANGE_JOIN)
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
    @locked = @scope_all ? locked_rows : []

    @may_see_bands = community_role("read") == "curator"
    @cohorts = @may_see_bands ? Analytics::MartChannelBands.cohorts : []
    @default_cohort = @cohorts.first
    @cohort = asked_cohort || @default_cohort
    @band_measures = @cohort ?
      Analytics::MartChannelBands.for_cohort(@cohort).to_a.group_by(&:measure) : {}
    @default_measure = @band_measures.keys.first
    @measure = @band_measures.key?(params[:measure]) ? params[:measure] : @default_measure
    @band_rows = @band_measures[@measure] || []
  end

  def show
    @channel = Channels::Audience.for(current_staff).find(params[:id])
    @backfill = ChannelBackfill.find_by(channel_id: @channel.channel_id)
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

  def opt_in_replies
    return refuse_backfill unless may_community?("ops.channel.backfill")

    channel = Channels::Audience.for(current_staff).find(params[:id])
    estimate = ChannelBackfill.estimate(channel)
    return refuse_spend(channel, estimate) if over_ceiling?(estimate)

    row = ChannelBackfill.opt_in!(
      channel_id: channel.channel_id,
      requested_by: current_staff.user_id,
      estimated_requests: estimate,
      threads_expected: channel.try(:thread_parents)
    )
    Fd::Audit.record(row, "turned_on",
      actor: current_staff.user_id, request_id: request.request_id,
      after: { "channel_id" => row.channel_id, "estimated_requests" => row.estimated_requests })

    redirect_to channel_path(channel.channel_id), notice: "thread replies queued for ##{channel.name}"
  end

  def opt_out_replies
    return refuse_backfill unless may_community?("ops.channel.backfill")

    channel = Channels::Audience.for(current_staff).find(params[:id])
    row = ChannelBackfill.find_by(channel_id: channel.channel_id)
    return redirect_to(channel_path(channel.channel_id), alert: "not opted in") if row.nil?

    row.opt_out!(by: current_staff.user_id)
    Fd::Audit.record(row, "turned_off",
      actor: current_staff.user_id, request_id: request.request_id,
      after: { "channel_id" => row.channel_id })

    redirect_to channel_path(channel.channel_id), notice: "thread replies stopped for ##{channel.name}"
  end

  private

  def refuse_backfill
    redirect_to channels_path,
      alert: Community::Access.why_not(current_staff, "ops.channel.backfill")
  end

  def over_ceiling?(estimate)
    return false if estimate.nil?
    return false if may_community?("ops.engine.sync")

    estimate > Engine::Setting.backfill_ceiling
  end

  def refuse_spend(channel, estimate)
    redirect_to channel_path(channel.channel_id),
      alert: "#{helpers.number_with_delimiter(estimate)} requests needs a steward"
  end

  def parse_range_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def asked_cohort
    wanted = parse_range_date(params[:cohort])
    wanted if wanted && @cohorts.include?(wanted)
  end

  LOCKED_SHOWN = 50

  def locked_rows
    mine = Channels::Audience.for(current_staff).select(:channel_id)
    rows = Channels::Audience.everything.where.not(channel_id: mine)
    rows = rows.where("dim_channel.name ILIKE ?", "%#{@q}%") if @q.present?
    rows.order(Arel.sql("dim_channel.name")).limit(LOCKED_SHOWN).to_a
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
