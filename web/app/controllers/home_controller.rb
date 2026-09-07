class HomeController < ApplicationController
  before_action { needs(:analytics) }

  OPEN_SHOWN = 25

  def index
    @panels = Panel.visible_to(current_account)
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
    @span_key = helpers.overview_span(params[:span])
    @span = helpers.span_of(@span_key)
    window = @span[:days] || YEAR_DAYS
    @spark = daily_window(window)
    @spark_prior = daily_window(window, back: window)
    @team_stats_prior = prior_row(window)

    @trend = @span[:granularity] == "monthly" ? monthly_window : @spark
    @trend_prior = @span[:granularity] == "monthly" ? [] : @spark_prior
  end

  YEAR_DAYS = 365
  PRIOR_SLACK = 2

  def daily_window(days, back: 0)
    return [] if @team_stats.nil? || days.zero?

    last = @team_stats.ds - back
    Analytics::MartTeamStatsDaily
      .where(ds: (last - (days - 1))..last)
      .order(:ds).to_a
  end

  def prior_row(days)
    return nil if @team_stats.nil? || days.zero?

    target = @team_stats.ds - days
    Analytics::MartTeamStatsDaily
      .where(ds: (target - PRIOR_SLACK)..target)
      .order(ds: :desc).first
  end

  def monthly_window
    Analytics::MartTeamStatsMonthly.order(month: :desc).limit(@span[:months]).to_a.reverse
  end
end
