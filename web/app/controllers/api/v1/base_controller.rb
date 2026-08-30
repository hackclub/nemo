module Api
  module V1
    class BaseController < ActionController::API
      BEARER = /\ABearer (.+)\z/i

      WINDOW = 60
      KEPT_FOR = 2.minutes

      before_action :require_a_token
      before_action :within_budget

      private

      attr_reader :current_token

      def within_budget
        limit = current_token.rate
        used = Rails.cache.increment(bucket, 1, expires_in: KEPT_FOR).to_i
        budget!(limit, used)
        return if used <= limit

        response.headers["Retry-After"] = left.to_s
        refuse(:too_many_requests, "rate_limited", retry_after: left)
      end

      def bucket
        "api/rate/#{current_token.id}/#{Time.current.to_i / WINDOW}"
      end

      def left
        WINDOW - (Time.current.to_i % WINDOW)
      end

      def budget!(limit, used)
        response.headers["RateLimit-Limit"] = limit.to_s
        response.headers["RateLimit-Remaining"] = [limit - used, 0].max.to_s
        response.headers["RateLimit-Reset"] = left.to_s
      end

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
        "api_off" => "the public_api flag is off",
        "invalid_token" => "no live key matches that digest",
        "revoked_token" => "that key was revoked, do not retry",
        "bad_channel_id" => "channel_id must match /\\AC[A-Z0-9]{8,}\\z/",
        "bad_user_id" => "every user id must match /\\A[UW][A-Z0-9]{8,}\\z/",
        "rate_limited" => "rate limit spent, see retry_after"
      }.freeze

      CALLER_ERRORS = [
        [401, "invalid_token", "Absent, malformed, or unknown Authorization header."],
        [401, "revoked_token", "Key exists but was revoked. Not retryable."],
        [422, "bad_channel_id", "channel_id did not match the pattern above."],
        [422, "bad_user_id", "user_id did not match the pattern above."],
        [429, "rate_limited", "Budget spent. Retry after retry_after seconds."],
        [503, "api_off", "The public_api flag is off. Applies to every route."]
      ].freeze

      def refuse(status, error, **extra)
        render json: { error: error, message: SAID[error] }.compact.merge(extra), status: status
      end
    end
  end
end
