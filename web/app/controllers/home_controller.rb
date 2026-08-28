class HomeController < ApplicationController
  before_action { needs(:analytics) }

  def index
    @team_stats = Analytics::MartTeamStatsDaily.order(ds: :desc).first
    @team_stats_prior =
      if @team_stats
        Analytics::MartTeamStatsDaily.where(ds: ..(@team_stats.ds - 28)).order(ds: :desc).first
      end
    @people_granularity = helpers.activity_granularity(params[:people_granularity])
    @messages_granularity = helpers.activity_granularity(params[:messages_granularity])

    case request.headers["X-Requested-With"]
    when "active-people"
      render partial: "active_people",
        locals: { activity_trend: activity_trend_for(@people_granularity),
                  granularity: @people_granularity },
        layout: false
      return
    when "member-messages"
      render partial: "member_messages",
        locals: { activity_trend: activity_trend_for(@messages_granularity),
                  granularity: @messages_granularity },
        layout: false
      return
    end

    @people_trend = activity_trend_for(@people_granularity)
    @messages_trend = activity_trend_for(@messages_granularity)
  end

  private

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
