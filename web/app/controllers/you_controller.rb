class YouController < ApplicationController
  before_action { needs(:analytics) }
  before_action :require_reading

  def show
    @profile = You::Profile.new(current_account.user_id, span: params[:span],
      start_on: params[:start], end_on: params[:end], streak: params[:streak],
      zone: viewer_zone)
    @names = Fd::Names.for([current_account.user_id])
  end
end
