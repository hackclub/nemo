module Fd
  class ChannelGuardsController < BaseController
    permit "channel.guard"

    def create
      channel_id = params[:channel_id].to_s.strip.upcase
      if ChannelGuard.live_for(channel_id)
        return refuse(channel_id, "this channel is guarded already")
      end

      writing do
        guard = ChannelGuard.create!(kind: ChannelGuard::BOT_ALLOWLIST, channel_id: channel_id,
          opened_by: current_account.user_id, reason: params[:reason].to_s.strip.presence)
        audit(guard, "opened")
      end

      redirect_to fd_channel_path(channel_id),
        notice: "the guard is on, and nothing is on the allow list yet"
    end

    def destroy
      channel_id = params[:channel_id].to_s.strip.upcase
      guard = ChannelGuard.live_for(channel_id)
      return refuse(channel_id, "this channel is not guarded") if guard.nil?

      writing do
        guard.update!(state: "lifted", lifted_at: Time.current,
          lifted_by: current_account.user_id)
        audit(guard, "lifted")
      end

      redirect_to fd_channel_path(channel_id), notice: "the guard is off, the list is kept"
    end

    private

    def refuse(channel_id, why)
      redirect_to fd_channel_path(channel_id), alert: why
    end
  end
end
