class JourneyController < ApplicationController
  before_action { needs(:analytics) }
  before_action :require_reading

  SCORECARD_PER_MONTH = 10
  LIFECYCLE_COHORTS = 12

  def acquisition
    asked = params[:growth_months].to_i
    @growth_span = HomeHelper::GROWTH_SPANS.include?(asked) ? asked : HomeHelper::DEFAULT_GROWTH_SPAN
    @growth_months = Analytics::MartGrowth.order(month: :desc).limit(@growth_span).to_a.reverse

    @lifecycle = Journey::Lifecycle.recent(LIFECYCLE_COHORTS)
  end

  def activation
    @newcomer_reach = Analytics::MartNewcomerChannels.where(channel_id: visible_channels)
      .order(:channel_id).first
    @newcomer_channels = Analytics::MartNewcomerChannels
      .where(channel_id: visible_channels)
      .ranked(Analytics::MartNewcomerChannels::DEFAULT_MEASURE, floor: HomeHelper::MIN_SAMPLE)

    scorecard = Analytics::MartChannelOnboardingScorecard.where(channel_id: visible_channels)
    @channel_scorecard = scorecard
      .where(newcomer_volume: HomeHelper::MIN_SAMPLE..)
      .order(post_month: :desc, newcomer_volume: :desc)
      .to_a
      .group_by(&:post_month)
      .transform_values { |rows| rows.first(SCORECARD_PER_MONTH) }
    @scorecard_months = @channel_scorecard.keys.sort.reverse
    @channel_scorecard_total = scorecard.count
  end

  def replies
    @response_rate = Analytics::MartResponseRate.order(post_month: :desc).limit(13)
    @response_rate_thin = @response_rate.count { |r| r.first_posts_checked < HomeHelper::MIN_SAMPLE }
    @response_rate_totals = Analytics::MartResponseRate.totals
    @fast_reply_classes = Analytics::MartFastReplyVsRetention
      .order(Arel.sql("case reply_class when 'fast' then 1 when 'slow' then 2 else 3 end"))
      .to_a
    @fast_reply_vs_retention = @fast_reply_classes.select do |row|
      row.newcomers >= HomeHelper::MIN_SAMPLE
    end
  end

  RETENTION_COHORTS = 12
  RECURRENCE_COHORTS = 12

  def retention
    @retention = Analytics::MartCohortRetention.measured
      .order(cohort_month: :desc).limit(RETENTION_COHORTS).to_a.reverse

    @recurrence = Analytics::MartOnboardingRecurrenceFunnel
      .where(searched: 1..)
      .order(cohort_month: :desc)
      .limit(RECURRENCE_COHORTS)
      .to_a
      .reverse
  end

  def distribution
    @may_read_members = Panel.visible?("journey.top_posters", current_account)
    @top_poster_months = @may_read_members ?
      Analytics::MartTopPosters.distinct.order(month: :desc).pluck(:month) : []
    @top_posters_month = asked_month(:top_posters_month) || @top_poster_months.first
    @top_posters = if @may_read_members
      Analytics::MartTopPosters.where(month: @top_posters_month).order(:rank).limit(10)
    else
      Analytics::MartTopPosters.none
    end

    @days_measured = @top_posters.map(&:days_measured).max.to_i
    @activity_bands = Analytics::MartActivityDistribution.order(:band_order).to_a
    @poster_bands = @activity_bands.reject { |b| b.band_order.zero? }
    @concentration = Analytics::MartParticipationConcentration.curve.to_a
  end

  private

  def asked_month(key)
    Date.iso8601(params[key].to_s)
  rescue ArgumentError
    nil
  end

  def visible_channels
    Channels::Audience.for(current_account).select(:channel_id)
  end
end
