module Fd
  module LogsActions
    NEEDS_EXPIRY = %w[shush temp_ban channel_ban].freeze
    NEEDS_CHANNEL = %w[channel_ban].freeze
    TAKES_CHANNEL = %w[channel_ban locked_thread].freeze

    private

    def type_key
      params[:type_key].to_s
    end

    def type_name
      FdHelper::ACTION_LABELS.fetch(type_key, type_key)
    end

    def action_objection
      return "pick what was done" unless FdHelper::ACTION_LABELS.key?(type_key)
      return "say who it was directed at" if params[:target_user_id].blank?
      if NEEDS_EXPIRY.include?(type_key) && params[:expires_on].blank?
        return "#{type_name.downcase} needs a date it runs until"
      end
      if NEEDS_CHANNEL.include?(type_key) && params[:channel_id].blank?
        return "#{type_name.downcase} needs a channel"
      end

      nil
    end

    def log_action(kase, at)
      Action.create!(
        case_id: kase.id,
        type_key: type_key,
        target_user_id: params[:target_user_id].strip,
        decided_by: current_staff.user_id,
        performed_by: current_staff.user_id,
        performed_at: at,
        source_app: Audit::SOURCE_APP,
        expires_at: expiry,
        cites_message_id: cited_message_id(kase),
        details: channel
      )
    end

    def cited_message_id(kase)
      asked = params[:cites_message_id].presence
      return nil if asked.nil?

      ThreadMessage.for_threads(kase.threads.to_a).find_by(id: asked)&.id
    end

    def expiry
      return nil unless NEEDS_EXPIRY.include?(type_key)

      params[:expires_on].presence&.to_date&.end_of_day
    end

    def channel
      return {} unless TAKES_CHANNEL.include?(type_key)
      return {} if params[:channel_id].blank?

      { "channel_id" => params[:channel_id].strip }
    end
  end
end
