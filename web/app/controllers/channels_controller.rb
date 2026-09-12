class ChannelsController < ApplicationController
  before_action { needs(:analytics) }

  PER_PAGE = 50
  RANGE_PRESETS = [7, 28, 90].freeze
  DEFAULT_RANGE_DAYS = 28

  SORT_SQL = {
    "name" => "#{Channels::Joins::SPINE}.name",
    "members" => "#{Channels::Joins::RANGE}.total_members",
    "created" => "#{Channels::Joins::SPINE}.date_created",
    "messages" => nil,
    "posters" => "#{Channels::Joins::RANGE}.members_who_posted",
    "viewers" => "#{Channels::Joins::RANGE}.members_who_viewed",
    "quiet" => "#{Channels::Joins::RANGE}.last_message_at",
    "change" => "#{Channels::Joins::MOMENTUM}.pct_change"
  }.freeze

  RANGE_JOIN = Channels::Joins::RANGE_JOIN
  MOMENTUM_JOIN = Channels::Joins::MOMENTUM_JOIN
  RANGE_COLUMNS = "#{Channels::Joins::SPINE}.*, " \
                  "#{Channels::Joins::RANGE}.members_who_posted AS range_posters, " \
                  "#{Channels::Joins::RANGE}.total_members AS range_members, " \
                  "#{Channels::Joins::RANGE}.members_who_viewed AS range_viewers, " \
                  "#{Channels::Joins::RANGE}.last_message_at AS range_last_post, " \
                  "#{Channels::Joins::MOMENTUM}.pct_change AS range_change, " \
                  "#{Channels::Joins::MOMENTUM}.prior_messages AS prior_messages, " \
                  "#{Channels::Joins::MOMENTUM}.prior_below_floor AS prior_thin, " \
                  "#{Channels::Joins::MOMENTUM}.prior_floor AS prior_floor".freeze

  def index
    @q = params[:q].to_s.strip
    @page = [params[:page].to_i, 0].max
    @sort = SORT_SQL.key?(params[:sort]) ? params[:sort] : "members"
    @direction = params[:direction] == "asc" ? "asc" : "desc"
    @view = params[:view] == "grid" ? "grid" : "table"
    @window = Channels::Window.from(params)
    @filter = Channels::Filter.from(params, measures: @window.measures)

    mine = Channels::Audience.for(current_account)
    @mine_total = mine.count

    scope = mine.joins(RANGE_JOIN).joins(MOMENTUM_JOIN)
    scope = scope.joins(@window.join) if @window.join
    scope = scope.where("#{Channels::Joins::SPINE}.name ILIKE ?", "%#{like_q}%") if @q.present?
    if (clause = @filter.clause)
      scope = scope.where(clause.first, *clause.drop(1))
    end

    @total = scope.count
    @peak_messages = scope.maximum(Arel.sql(@window.measure_sql)).to_i

    @channels = scope
      .select("#{RANGE_COLUMNS}, #{@window.column}")
      .order(Arel.sql(order_clause))
      .limit(PER_PAGE)
      .offset(@page * PER_PAGE)
      .to_a
    @has_more = (@page + 1) * PER_PAGE < @total
    @pages = [(@total / PER_PAGE.to_f).ceil, 1].max

    @momentum = Analytics::MartChannelMomentum.top
    @momentum_head = @momentum.first
    @cohorts = Analytics::MartChannelBands.cohorts
    @default_cohort = @cohorts.first
    @cohort = asked_cohort || @default_cohort
    @band_measures = @cohort ?
      Analytics::MartChannelBands.for_cohort(@cohort).to_a.group_by(&:measure) : {}
    @default_measure = @band_measures.keys.first
    @measure = @band_measures.key?(params[:measure]) ? params[:measure] : @default_measure
    @band_rows = @band_measures[@measure] || []
  end

  def show
    @channel = Channels::Audience.for(current_account).find_by(channel_id: params[:id])
    return refuse_channel if @channel.nil?

    @backfill = ChannelBackfill.find_by(channel_id: @channel.channel_id)
    @activity_trend = Analytics::MartChannelActivity.where(channel_id: @channel.channel_id).order(:window_start)
    @scorecard_rows = Analytics::MartChannelOnboardingScorecard
      .where(channel_id: @channel.channel_id, newcomer_volume: HomeHelper::MIN_SAMPLE..)
      .order(:post_month)
    @clock = Community::Clock.for_channel(@channel.channel_id)

    coverage = Slack::Analytics.coverage
    last_available = coverage ? Date.iso8601(coverage["end_date"]) : (Date.current - 2)
    custom_start = parse_range_date(params[:start])
    custom_end = parse_range_date(params[:end])

    floor = [@channel.date_created&.to_date, last_available - 400].compact.max
    if custom_start || custom_end
      @range_preset = nil
      @end_date = (custom_end || last_available).clamp(floor, last_available)
      @start_date = (custom_start || (@end_date - (DEFAULT_RANGE_DAYS - 1)))
        .clamp(floor, last_available)
      @start_date = @end_date if @start_date > @end_date
    else
      @range_preset = RANGE_PRESETS.include?(params[:days].to_i) ? params[:days].to_i : DEFAULT_RANGE_DAYS
      @end_date = last_available
      @start_date = @end_date - (@range_preset - 1)
    end

    @range_max = last_available
    @range_min = floor
    all_time_start = @channel.date_created&.to_date || (last_available - 400)
    @range, @all_time = Slack::Analytics.channel_windows(
      channel_id: @channel.channel_id, name: @channel.name, privacy: @channel.visibility,
      windows: [[@start_date, @end_date], [all_time_start, last_available]]
    )
    @member_count = @all_time.stats&.dig("total_members_count")
  end

  def opt_in_replies
    return refuse_backfill unless may_community?("ops.channel.backfill")

    channel = Channels::Audience.for(current_account).find_by(channel_id: params[:id])
    return refuse_channel if channel.nil?

    estimate = ChannelBackfill.estimate(channel)
    return refuse_spend(channel, estimate) if over_ceiling?(estimate)

    row = ChannelBackfill.opt_in!(
      channel_id: channel.channel_id,
      requested_by: current_account.user_id,
      estimated_requests: estimate,
      threads_expected: channel.try(:thread_parents)
    )
    Fd::Audit.record(row, "turned_on",
      actor: current_account.user_id, request_id: request.request_id,
      after: { "channel_id" => row.channel_id, "estimated_requests" => row.estimated_requests })

    redirect_to channel_path(channel.channel_id), notice: "thread replies queued for ##{channel.name}"
  end

  def opt_out_replies
    return refuse_backfill unless may_community?("ops.channel.backfill")

    channel = Channels::Audience.for(current_account).find_by(channel_id: params[:id])
    return refuse_channel if channel.nil?

    row = ChannelBackfill.find_by(channel_id: channel.channel_id)
    return redirect_to(channel_path(channel.channel_id), alert: "not opted in") if row.nil?

    row.opt_out!(by: current_account.user_id)
    Fd::Audit.record(row, "turned_off",
      actor: current_account.user_id, request_id: request.request_id,
      after: { "channel_id" => row.channel_id })

    redirect_to channel_path(channel.channel_id), notice: "thread replies stopped for ##{channel.name}"
  end

  private

  def like_q
    ActiveRecord::Base.sanitize_sql_like(@q.to_s)
  end

  def refuse_backfill
    redirect_to channels_path,
      alert: Community::Access.why_not(current_account, "ops.channel.backfill")
  end

  def over_ceiling?(estimate)
    return false if estimate.nil?
    return false if may_community?("ops.engine")

    estimate > Engine::Setting.backfill_ceiling
  end

  def refuse_spend(channel, estimate)
    redirect_to channel_path(channel.channel_id),
      alert: "#{helpers.number_with_delimiter(estimate)} requests needs engine.manage"
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

  def refuse_channel
    known = Channels::Audience.everything.exists?(channel_id: params[:id])
    said = if known
      Community::Access.why_not(current_account, "analytics.channel.read") ||
        "that channel is not shared with you"
    else
      "no such channel"
    end
    redirect_to channels_path(q: params[:id]), alert: said
  end

  def sort_sql
    SORT_SQL[@sort] || @window.measure_sql
  end

  def order_clause
    metric = "#{sort_sql} #{@direction} NULLS LAST"
    return metric if @q.blank?

    ql = like_q.downcase
    rank = ActiveRecord::Base.sanitize_sql_array(
      ["CASE WHEN lower(#{Channels::Joins::SPINE}.name) = ? THEN 0 " \
       "WHEN lower(#{Channels::Joins::SPINE}.name) LIKE ? THEN 1 ELSE 2 END", ql, "#{ql}%"]
    )
    "#{rank}, #{metric}"
  end
end
