class ChannelsController < ApplicationController
  before_action { needs(:analytics) }
  before_action :freshen_appointments, only: :show

  PER_PAGE = 50
  RANGE_PRESETS = [7, 30, 90].freeze
  DEFAULT_RANGE_DAYS = 30

  VIEWS = {
    "overview" => "Overview",
    "activity" => "Activity",
    "newcomers" => "Newcomers",
    "messages" => "Messages",
    "neighbours" => "Neighbours"
  }.freeze
  DEFAULT_VIEW = "overview".freeze
  RANGED_VIEWS = %w[overview messages].freeze

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
    @unmeasured = unmeasured_tail

    @momentum = Analytics::MartChannelMomentum.top
    @newcomer_cohorts = Analytics::MartNewcomerChannels.cohorts
    @newcomer_cohort = Analytics::MartNewcomerChannels.cohort(params[:newcomers])
    @opportunity = @newcomer_cohort && Channels::Map.opportunity(@newcomer_cohort)
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
    return unmeasured_channel if @channel.nil? && may_see_unmeasured?
    return refuse_channel if @channel.nil?

    id = @channel.channel_id
    @view = VIEWS.key?(params[:view]) ? params[:view] : DEFAULT_VIEW
    @backfill = ChannelBackfill.find_by(channel_id: id)
    @snapshot = Analytics::MartChannelRange.find_by(channel_id: id)
    @standing = Analytics::MartChannelMomentum.find_by(channel_id: id)
    @team_stats = Analytics::MartTeamStatsDaily.order(ds: :desc).first

    coverage = Slack::Analytics.coverage
    proxy_edge = coverage ? Date.iso8601(coverage["end_date"]) : (Date.current - 2)
    last_available = Channels::Pulse.edge || proxy_edge
    settle_range(last_available)

    @crowd = Channels::Crowd.for(id, month: parse_range_date(params[:month]))
    @member_count = @snapshot&.total_members

    case @view
    when "overview"
      @pulse = Channels::Pulse.for(id, from: @start_date, to: @end_date)
      @clock = Community::Clock.for_channel(id, zone: viewer_zone)
      @range = Slack::Analytics.channel_activity(
        channel_id: id, name: @channel.name, privacy: @channel.visibility,
        from: @start_date.clamp(@proxy_min, proxy_edge),
        to: @end_date.clamp(@proxy_min, proxy_edge)
      )
    when "newcomers"
      @welcome = Channels::Welcome.for(id)
      @scorecard_rows = Analytics::MartChannelOnboardingScorecard
        .where(channel_id: id, newcomer_volume: HomeHelper::MIN_SAMPLE..)
        .order(:post_month)
    when "messages"
      @pulse = Channels::Pulse.for(id, from: @start_date, to: @end_date)
    when "neighbours"
      @neighbours = Analytics::MartChannelNeighbours
        .where(channel_id: id, neighbour_archived: false)
        .order(:neighbour_rank).to_a
    end
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

  def settle_range(last_available)
    floor = [@channel.date_created&.to_date, last_available - 400].compact.max
    floor = [floor, last_available].min
    custom_start = parse_range_date(params[:start])
    custom_end = parse_range_date(params[:end])

    if custom_start || custom_end
      @range_preset = nil
      @end_date = (custom_end || last_available).clamp(floor, last_available)
      @start_date = (custom_start || (@end_date - (DEFAULT_RANGE_DAYS - 1)))
        .clamp(floor, last_available)
      @start_date = @end_date if @start_date > @end_date
    else
      @range_preset = RANGE_PRESETS.include?(params[:days].to_i) ? params[:days].to_i : DEFAULT_RANGE_DAYS
      @end_date = last_available
      @start_date = [@end_date - (@range_preset - 1), floor].max
    end

    @range_max = last_available
    @range_min = floor
    @proxy_min = floor
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

  def freshen_appointments
    ::Prometheus::Mirror.freshen(current_account&.user_id)
  end

  def unmeasured_tail
    return [] if @has_more

    held = Channels::Audience.unmeasured_for(current_account)
    return held if @q.blank?

    held.select { |channel_id| channel_id.downcase.include?(@q.downcase) }
  end

  def may_see_unmeasured?
    return false if current_account.nil?
    return false if Analytics::DimChannel.exists?(channel_id: params[:id])

    ::Prometheus::Appointment.managing.for_person(current_account.user_id)
      .exists?(channel_id: params[:id])
  end

  def unmeasured_channel
    @channel_id = params[:id]
    render :unmeasured
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
