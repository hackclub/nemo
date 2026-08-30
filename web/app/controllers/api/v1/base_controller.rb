module Api
  module V1
    class BaseController < ActionController::API
      BEARER = /\ABearer (.+)\z/i

      before_action :require_a_token

      private

      attr_reader :current_token

      def require_a_token
        return refuse(:service_unavailable, "api_off") if Fd::Flag.off?(:public_api)

        key = presented
        return refuse(:unauthorized, "invalid_token") if key.blank?

        token = ::Api::Token.find_by(digest: ::Api::Token.digest_of(key))
        return refuse(:unauthorized, "invalid_token") if token.nil?
        return refuse(:unauthorized, "revoked_token") if token.revoked?

        @current_token = token
        token.used!
      end

      def presented
        request.authorization.to_s[BEARER, 1]
      end

      SAID = {
        "api_off" => "the mnemosyne api is turned off",
        "invalid_token" => "no live token matches that key",
        "revoked_token" => "that token was revoked and will not come back",
        "bad_channel_id" => "a channel id looks like C0123456789",
        "bad_user_id" => "a user id looks like U0123456789",
        "channel_not_found" => "no public channel with that id",
        "user_not_found" => "no member with that id"
      }.freeze

      def refuse(status, error, **extra)
        render json: { error: error, message: SAID[error] }.compact.merge(extra), status: status
      end
    end
  end
end
