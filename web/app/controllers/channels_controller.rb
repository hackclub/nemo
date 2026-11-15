class ChannelsController < ApplicationController
  before_action { require_flag(:analytics) }
  before_action :refresh_appointments, only: :show

  PER_PAGE = 50
  RANGE_PRESETS = [7, 30, 90].freeze
  DEFAULT_RANGE_DAYS = 30

  VIEWS = {
    "overview" => "Overview",
    "activity" => "Activity",
    "newcomers" => "Newcomers",
    "messages" => "Messages",
    "posts" => "Posts",
    "neighbours" => "Neighbours"
  }.freeze
  DEFAULT_VIEW = "overview".freeze
  RANGED_VIEWS = %w[overview messages].freeze
  POSTS_VIEW = "posts".freeze

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

    visible_channels = Channels::Audience.for(current_account)
    @visible_total = visible_channels.count

    scope = visible_channels.joins(RANGE_JOIN).joins(MOMENTUM_JOIN)
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
    @newcomer_cohort = Analytics::MartNewcomerChannels.cohort(params[:newcomers], among: @newcomer_cohorts)
    @opportunity = @newcomer_cohort && Channels::Map.opportunity(@newcomer_cohort)
    @momentum_head = @momentum.first
    @cohorts = Analytics::MartChannelBands.cohorts
    @default_cohort = @cohorts.first
    @cohort = requested_cohort || @default_cohort
    @band_measures = @cohort ?
      Analytics::MartChannelBands.for_cohort(@cohort).to_a.group_by(&:measure) : {}
    @default_measure = @band_measures.keys.first
    @measure = @band_measures.key?(params[:measure]) ? params[:measure] : @default_measure
    @band_rows = @band_measures[@measure] || []
  end

  def show
    @channel = Channels::Audience.for(current_account).find_by(channel_id: params[:id])
    return unmeasured_channel if @channel.nil? && may_see_unmeasured?
    return redirect_channel_denied if @channel.nil?

    id = @channel.channel_id
    @views = views_for(id)
    @view = @views.key?(params[:view]) ? params[:view] : DEFAULT_VIEW
    @backfill = ChannelBackfill.find_by(channel_id: id)
    @snapshot = Analytics::MartChannelRange.find_by(channel_id: id)
    @standing = Analytics::MartChannelMomentum.find_by(channel_id: id)
    @team_stats = Analytics::MartTeamStatsDaily.order(ds: :desc).first

    coverage = Slack::Analytics.coverage
    proxy_edge = coverage ? Date.iso8601(coverage["end_date"]) : (Date.current - 2)
    last_available = Channels::Pulse.edge || proxy_edge
    assign_date_range(last_available)

    @member_counts = Channels::Crowd.for(id, month: parse_range_date(params[:month]))
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
    when "posts"
      @posts = Channels::Posts.for(channel_id: id, subject_id: current_account.user_id)
      @names = Fd::Names.for(mentioned_in(@posts) + @posts.map(&:author_id))
      @mentioned_channels = Analytics::DimChannel.where(channel_id: channel_ids_in(@posts))
        .pluck(:channel_id, :name).to_h
      @emoji = Slack::Emoji.for(emoji_in(@posts))
    when "neighbours"
      @neighbours = Analytics::MartChannelNeighbours
        .where(channel_id: id, neighbour_archived: false)
        .order(:neighbour_rank).to_a
    end
  end

  def opt_in_replies
    return redirect_backfill_denied unless may_community?("ops.channel.backfill")

    channel = Channels::Audience.for(current_account).find_by(channel_id: params[:id])
    return redirect_channel_denied if channel.nil?

    estimate = ChannelBackfill.estimate(channel)
    return redirect_over_ceiling(channel, estimate) if over_ceiling?(estimate)

    row = ChannelBackfill.opt_in!(
      channel_id: channel.channel_id,
      requested_by: current_account.user_id,
      estimated_requests: estimate,
      threads_expected: channel.try(:thread_parents)
    )
    Fd::Audit.record(row, "turned_on",
      actor: current_account.user_id, request_id: request.request_id,
      after: { "channel_id" => row.channel_id, "estimated_requests" => row.estimated_requests })

    redirect_to channel_path(channel.channel_id), notice: "Thread replies queued for ##{channel.name}"
  end

  def opt_out_replies
    return redirect_backfill_denied unless may_community?("ops.channel.backfill")

    channel = Channels::Audience.for(current_account).find_by(channel_id: params[:id])
    return redirect_channel_denied if channel.nil?

    row = ChannelBackfill.find_by(channel_id: channel.channel_id)
    return redirect_to(channel_path(channel.channel_id), alert: "Not opted in") if row.nil?

    row.opt_out!(by: current_account.user_id)
    Fd::Audit.record(row, "turned_off",
      actor: current_account.user_id, request_id: request.request_id,
      after: { "channel_id" => row.channel_id })

    redirect_to channel_path(channel.channel_id), notice: "Thread replies stopped for ##{channel.name}"
  end

  private

  def views_for(channel_id)
    return VIEWS if Channels::Activity.visible?(channel_id)

    VIEWS.except(POSTS_VIEW)
  end

  def mentioned_in(posts)
    posts.flat_map { |post| Fd::Mentions.ids(post.message&.dig("text")) }.uniq
  end

  def channel_ids_in(posts)
    posts.flat_map { |post| Fd::Mentions.channel_ids(post.message&.dig("text")) }.uniq
  end

  def emoji_in(posts)
    posts.flat_map do |post|
      Slack::RichText.emoji_names(post.message) + post.reactions_label.map { |reaction| reaction["name"] }
    end.uniq
  end

  def like_q
    ActiveRecord::Base.sanitize_sql_like(@q.to_s)
  end

  def redirect_backfill_denied
    redirect_to channels_path,
      alert: Community::Access.why_not(current_account, "ops.channel.backfill")
  end

  def over_ceiling?(estimate)
    return false if estimate.nil?
    return false if may_community?("ops.engine")

    estimate > Engine::Setting.backfill_ceiling
  end

  def redirect_over_ceiling(channel, estimate)
    redirect_to channel_path(channel.channel_id),
      alert: "#{helpers.number_with_delimiter(estimate)} requests requires engine.manage"
  end

  def assign_date_range(last_available)
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

  def requested_cohort
    cohort_date = parse_range_date(params[:cohort])
    cohort_date if cohort_date && @cohorts.include?(cohort_date)
  end

  def refresh_appointments
    ::Prometheus::Mirror.refresh_if_due(current_account&.user_id)
  end

  def unmeasured_tail
    return [] if @has_more

    channel_ids = Channels::Audience.unmeasured_for(current_account)
    return channel_ids if @q.blank?

    channel_ids.select { |channel_id| channel_id.downcase.include?(@q.downcase) }
  end

  def may_see_unmeasured?
    return false if current_account.nil?
    return false if Analytics::DimChannel.exists?(channel_id: params[:id])

    ::Prometheus::Appointment.for_person(current_account.user_id).exists?(channel_id: params[:id])
  end

  def unmeasured_channel
    @channel_id = params[:id]
    render :unmeasured
  end

  def redirect_channel_denied
    channel_exists = Channels::Audience.everything.exists?(channel_id: params[:id])
    message = if channel_exists
      Community::Access.why_not(current_account, "analytics.channel.read") ||
        "Channel not shared"
    else
      "Channel not found"
    end
    redirect_to channels_path(q: params[:id]), alert: message
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
