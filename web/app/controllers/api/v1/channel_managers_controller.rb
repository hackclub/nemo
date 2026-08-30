module Api
  module V1
    class ChannelManagersController < BaseController
      CHANNEL = /\AC[A-Z0-9]{8,}\z/
      MEMBER = /\A[UW][A-Z0-9]{8,}\z/
      CAPABILITY = "channel_manager".freeze

      def show
        channel = params[:channel_id].to_s
        user = params[:user_id].to_s

        return refuse(:unprocessable_content, "bad_channel_id") unless CHANNEL.match?(channel)
        return refuse(:unprocessable_content, "bad_user_id") unless MEMBER.match?(user)

        render json: { channel_id: channel, user_id: user }.merge(answer(channel, user))
      end

      private

      def answer(channel, user)
        return withheld(channel, user) unless ::Api::Consent.granted?(user, CAPABILITY)

        ChannelManagers.freshen(channel)
        held = ::Api::ChannelManager.find_by(channel_id: channel, user_id: user)
        log(channel, user, held ? ::Api::RequestLog::MANAGER : ::Api::RequestLog::NOT_MANAGER)

        { consent: "granted", is_manager: held.present? }.merge(freshness(channel))
      end

      def withheld(channel, user)
        log(channel, user, ::Api::RequestLog::WITHHELD)

        { consent: "withheld", is_manager: nil, opt_in_url: "#{request.base_url}/you/api" }
      end

      def freshness(channel)
        swept = ChannelManagers.swept_at(channel)

        { synced_at: swept&.utc&.iso8601,
          stale: swept.nil? || swept < ChannelManagers::TTL.ago }
      end

      def log(channel, user, outcome)
        ::Api::RequestLog.log!(current_token.id, channel, [[user, outcome]])
      end
    end
  end
end
