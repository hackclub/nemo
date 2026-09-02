class HomeController < ApplicationController
  before_action { needs(:analytics) }

  OPEN_SHOWN = 25

  def index
    @panels = Panel.visible_to(current_staff)
    return front_door if @panels.empty?

    workspace
  end

  private

  def front_door
    @open_channels = Channels::Audience.open_to_all
      .order(Arel.sql("dim_channel.name"))
      .limit(OPEN_SHOWN)
      .to_a
    render :front_door
  end

  def workspace
    @team_stats = Analytics::MartTeamStatsDaily.order(ds: :desc).first
    @team_stats_prior =
      if @team_stats
        Analytics::MartTeamStatsDaily.where(ds: ..(@team_stats.ds - 28)).order(ds: :desc).first
      end
    @people_granularity = helpers.activity_granularity(params[:people_granularity])
    @messages_granularity = helpers.activity_granularity(params[:messages_granularity])

    @people_trend = activity_trend_for(@people_granularity)
    @messages_trend = activity_trend_for(@messages_granularity)
  end

  def activity_trend_for(granularity)
    @activity_trends ||= {}
    @activity_trends[granularity] ||=
      if granularity == "monthly"
        Analytics::MartTeamStatsMonthly
          .where("is_complete or month = ?", Date.current.beginning_of_month)
          .order(month: :desc).limit(12).to_a.reverse
      else
        Analytics::MartTeamStatsDaily.order(ds: :desc).limit(90).to_a.reverse
      end
  end
end
