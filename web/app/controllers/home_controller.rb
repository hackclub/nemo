class HomeController < ApplicationController
  before_action :require_community_manager

  def index
    @cohort_months = Analytics::MartOnboardingFunnel.order(cohort_month: :desc).pluck(:cohort_month)
    selected_cohort = params[:cohort_month].presence&.then { |d| Date.parse(d) } || @cohort_months.first
    @onboarding_funnel = Analytics::MartOnboardingFunnel.find_by(cohort_month: selected_cohort)

    if request.headers["X-Requested-With"] == "onboarding-funnel"
      render partial: "onboarding_funnel",
        locals: { onboarding_funnel: @onboarding_funnel, cohort_months: @cohort_months },
        layout: false
      return
    end

    @recurrence_cohort_months = Analytics::MartOnboardingRecurrenceFunnel.order(cohort_month: :desc).pluck(:cohort_month)
    @recurrence_month = params[:recurrence_month].presence&.then { |d| Date.parse(d) } || @recurrence_cohort_months.first
    @recurrence_funnel = Analytics::MartOnboardingRecurrenceFunnel.find_by(cohort_month: @recurrence_month)

    if request.headers["X-Requested-With"] == "recurrence-funnel"
      render partial: "recurrence_funnel",
        locals: { recurrence_funnel: @recurrence_funnel, recurrence_cohort_months: @recurrence_cohort_months, recurrence_month: @recurrence_month },
        layout: false
      return
    end

    @team_stats = Analytics::MartTeamStatsDaily.order(ds: :desc).first
    @activity_granularity = helpers.activity_granularity(params[:activity_granularity])
    @activity_trend =
      if @activity_granularity == "monthly"
        Analytics::MartTeamStatsMonthly
          .where("is_complete or month = ?", Date.current.beginning_of_month)
          .order(month: :desc).limit(12).to_a.reverse
      else
        Analytics::MartTeamStatsDaily.order(ds: :desc).limit(90).to_a.reverse
      end

    if request.headers["X-Requested-With"] == "activity-charts"
      render partial: "activity_charts",
        locals: { activity_trend: @activity_trend, granularity: @activity_granularity },
        layout: false
      return
    end

    @top_poster_months = Analytics::MartTopPosters.distinct.order(month: :desc).pluck(:month)
    @top_posters_month = params[:top_posters_month].presence&.then { |d| Date.parse(d) } || @top_poster_months.first
    @top_posters = Analytics::MartTopPosters.where(month: @top_posters_month).order(:rank).limit(10)

    if request.headers["X-Requested-With"] == "top-posters"
      render partial: "top_posters",
        locals: { top_posters: @top_posters, top_poster_months: @top_poster_months, top_posters_month: @top_posters_month },
        layout: false
      return
    end
    @growth_months = Analytics::MartGrowth.order(month: :desc).limit(6).to_a.reverse
    @top_channels = Analytics::MartChannelRange
      .order(messages_posted_by_members: :desc)
      .limit(8)
    @activity_bands = Analytics::MartActivityDistribution.order(:band_order)
    @account_types = Analytics::MartAccountType.where.not(account_type: ["Owner", "Admin", "Org Owner"]).order(members: :desc)
    @channel_scorecard = Analytics::MartChannelOnboardingScorecard
      .where(newcomer_volume: HomeHelper::MIN_SAMPLE..)
      .order(post_month: :desc, newcomer_volume: :desc).limit(10)
    @fast_reply_vs_retention = Analytics::MartFastReplyVsRetention
      .where(newcomers: HomeHelper::MIN_SAMPLE..)
      .order(fast_reply: :desc)
  end

  private

  def require_community_manager
    return if current_staff.community_manager?

    redirect_to fire_engine_root_path
  end
end
