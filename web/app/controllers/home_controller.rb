class HomeController < ApplicationController
  before_action :require_community_manager

  def index
    @activation = Analytics::MartActivation.take
    @participation = Analytics::MartParticipation.order(window_end: :desc).first
    @active_members = Analytics::DimMember.where(deactivated_at: nil).count
    @growth_months = Analytics::MartGrowth.order(month: :desc).limit(6).to_a.reverse
    @top_channels = Analytics::MartChannelActivity.order(messages_posted: :desc).limit(8)
    @activity_bands = Analytics::MartActivityDistribution.order(:band_order)
    @account_types = Analytics::MartAccountType.order(members: :desc)
    @cohort_months = Analytics::MartOnboardingFunnel.order(cohort_month: :desc).pluck(:cohort_month)
    selected_cohort = params[:cohort_month].presence&.then { |d| Date.parse(d) } || @cohort_months.first
    @onboarding_funnel = Analytics::MartOnboardingFunnel.find_by(cohort_month: selected_cohort)
    @channel_scorecard = Analytics::MartChannelOnboardingScorecard.order(post_month: :desc, newcomer_volume: :desc).limit(10)
    @fast_reply_vs_retention = Analytics::MartFastReplyVsRetention.order(fast_reply: :desc)
    @recurrence_funnel = Analytics::MartOnboardingRecurrenceFunnel.take
    @message_depth = Analytics::MartMessageDepthDistribution.order(:threshold)
  end

  private

  def require_community_manager
    return if current_staff.community_manager?

    redirect_to fire_engine_root_path
  end
end
