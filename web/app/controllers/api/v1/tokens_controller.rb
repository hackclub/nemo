module Api
  module V1
    class TokensController < BaseController
      def show
        render json: {
          name: current_token.name,
          prefix: current_token.prefix,
          owner_user_id: current_token.owner_user_id,
          rate_per_minute: current_token.rate,
          created_at: current_token.created_at.utc.iso8601,
          last_used_at: current_token.last_used_at&.utc&.iso8601
        }
      end
    end
  end
end
