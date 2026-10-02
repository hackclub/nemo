module Fd
  class ChannelPurgesController < BaseController
    permit "channel.purge", only: :create
    permit "channel.guard", only: :show

    LONGEST_REASON = 500

    def show
      @purge = ChannelPurge.for_channel(channel_id).find(params[:id])
      @channel = Analytics::DimChannel.find_by(channel_id: channel_id)
      @threads = ChannelPurge::Reading.new(@purge.kept)
      @names = Names.for(@purge.people_named)
    end

    def create
      problem = objection
      return refuse(problem) if problem

      writing do
        purge = ChannelPurge.create!(channel_id: channel_id, wanted: wanted,
          reason: reason, asked_by: current_account.user_id)
        audit(purge, "queued", after: { "channel_id" => channel_id, "wanted" => wanted })
      end

      redirect_to here, notice: "nemo is taking down the last #{wanted} here"
    rescue ActiveRecord::RecordNotUnique
      refuse("a purge is already running here")
    end

    private

    def channel_id
      @channel_id ||= params[:channel_id].to_s.strip.upcase
    end

    def wanted
      @wanted ||= params[:wanted].to_s.strip.to_i
    end

    def reason
      @reason ||= params[:reason].to_s.strip
    end

    def here
      fd_channel_path(channel_id, tab: "purge")
    end

    def objection
      unless wanted.between?(1, ChannelPurge::MOST)
        return "say how many, from 1 to #{ChannelPurge::MOST}"
      end
      return "say why" if reason.blank?
      return "keep it under #{LONGEST_REASON} characters" if reason.length > LONGEST_REASON
      return "a purge is already running here" if ChannelPurge.waiting_on?(channel_id)

      nil
    end

    def refuse(why)
      redirect_to here, alert: why
    end
  end
end
