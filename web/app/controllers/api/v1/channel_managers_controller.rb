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
        return refuse(:not_found, "channel_not_found") unless known?(channel)

        found = answers(channel, [user])
        render json: { channel_id: channel }.merge(found[:results].first).merge(found[:about])
      end

      def check
        channel = params[:channel_id].to_s
        users = Array(params[:user_ids]).map(&:to_s)
        most = ::Api::Setting.value("batch_max")

        return refuse(:unprocessable_content, "bad_channel_id") unless CHANNEL.match?(channel)
        return refuse(:unprocessable_content, "too_many_subjects", most: most) if users.size > most
        return refuse(:unprocessable_content, "bad_user_id") unless users.all? { MEMBER.match?(_1) }
        return refuse(:not_found, "channel_not_found") unless known?(channel)

        found = answers(channel, users.uniq)
        render json: { channel_id: channel }.merge(found[:about]).merge(results: found[:results])
      end

      private

      def known?(channel_id)
        Analytics::DimChannel.exists?(channel_id: channel_id)
      end

      def answers(channel, users)
        granted = ::Api::Consent.where(user_id: users, capability: CAPABILITY,
          state: ::Api::Consent::GRANTED).pluck(:user_id).to_set
        held = held_by(channel, granted)
        swept = granted.any? ? ChannelManagers.swept_at(channel) : nil

        outcomes = []
        results = users.map do |user|
          row = one(user, granted, held)
          outcomes << [user, outcome_of(row)]
          row
        end

        ::Api::RequestLog.log!(current_token.id, channel, outcomes)
        { results: results, about: about(granted, swept) }
      end

      def held_by(channel, granted)
        return {} if granted.empty?

        ChannelManagers.freshen(channel)
        ::Api::ChannelManager.where(channel_id: channel, user_id: granted.to_a)
          .pluck(:user_id, :assigned_at).to_h
      end

      def one(user, granted, held)
        unless granted.include?(user)
          return { user_id: user, consent: "withheld", is_manager: nil,
                   opt_in_url: "#{request.base_url}/you/api" }
        end

        row = { user_id: user, consent: "granted", is_manager: held.key?(user) }
        row[:since] = held[user]&.utc&.iso8601 if held.key?(user)
        row
      end

      def outcome_of(row)
        return ::Api::RequestLog::WITHHELD if row[:consent] == "withheld"

        row[:is_manager] ? ::Api::RequestLog::MANAGER : ::Api::RequestLog::NOT_MANAGER
      end

      def about(granted, swept)
        return {} if granted.empty?

        { synced_at: swept&.utc&.iso8601,
          stale: swept.nil? || swept < ChannelManagers::TTL.ago }
      end
    end
  end
end
