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

    @team_stats = Analytics::MartTeamStats.take
    @active_members = Analytics::DimMember.where(is_bot: false).where.not(claimed_at: nil).count
    @growth_months = Analytics::MartGrowth.order(month: :desc).limit(6).to_a.reverse
    @top_channels = Analytics::MartChannelActivity
      .where("window_start >= ?", Date.current - 30)
      .group(:channel_id, :name, :visibility)
      .select(
        "channel_id",
        "name",
        "visibility",
        "sum(messages_posted) as messages_posted",
        "sum(members_who_posted) as members_who_posted",
        "sum(reactions_added) as reactions_added",
        "sum(huddles_initiated) as huddles_initiated"
      )
      .order("sum(messages_posted) desc")
      .limit(8)
    @activity_bands = Analytics::MartActivityDistribution.order(:band_order)
    @account_types = Analytics::MartAccountType.where.not(account_type: ["Owner", "Admin", "Org Owner"]).order(members: :desc)
    @channel_scorecard = Analytics::MartChannelOnboardingScorecard.order(post_month: :desc, newcomer_volume: :desc).limit(10)
    @fast_reply_vs_retention = Analytics::MartFastReplyVsRetention.order(fast_reply: :desc)
    @message_depth = Analytics::MartMessageDepthDistribution.order(:threshold)
  end

  private

  def require_community_manager
    return if current_staff.community_manager?

    redirect_to fire_engine_root_path
  end
end
