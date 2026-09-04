module Fd
  module LogsActions
    NEEDS_EXPIRY = Action::NEEDS_EXPIRY
    NEEDS_CHANNEL = Action::NEEDS_CHANNEL
    TAKES_CHANNEL = Action::TAKES_CHANNEL
    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    private

    def target_user_id
      params[:target_user_id].to_s.strip
    end

    def channel_id
      params[:channel_id].to_s.strip
    end

    def type_key
      params[:type_key].to_s
    end

    def type_name
      FdHelper::ACTION_LABELS.fetch(type_key, type_key)
    end

    def action_objection
      return "pick what was done" unless FdHelper::ACTION_LABELS.key?(type_key)
      return "say who it was directed at" if target_user_id.blank?
      return "#{target_user_id} is not a member id" unless target_user_id.match?(MEMBER_ID)
      if NEEDS_EXPIRY.include?(type_key)
        return "#{type_name.downcase} needs a date it runs until" if params[:expires_on].blank?
        return "#{params[:expires_on]} is not a date" if expiry.nil?
      end
      if NEEDS_CHANNEL.include?(type_key) && channel_id.blank?
        return "#{type_name.downcase} needs a channel"
      end
      if channel_id.present? && !channel_id.match?(SlackLink::CHANNEL)
        return "#{channel_id} is not a channel id"
      end
      if params[:reason].to_s.strip.blank?
        return wrong!(:reason, "say why this was the answer", params[:reason])
      end

      nil
    end

    def log_action(kase, at)
      Action.create!(
        case_id: kase.id,
        type_key: type_key,
        target_user_id: target_user_id,
        decided_by: current_account.user_id,
        performed_by: current_account.user_id,
        performed_at: at,
        source_app: Audit::SOURCE_APP,
        expires_at: expiry,
        cites_message_id: cited_message_id(kase),
        reason: params[:reason].to_s.strip,
        category_key: chosen_category(kase),
        details: channel
      )
    end

    def chosen_category(kase)
      asked = params[:category_key].to_s
      return asked if Case::CATEGORIES.include?(asked)

      kase.category_key
    end

    def cited_message_id(kase)
      asked = params[:cites_message_id].presence
      return nil if asked.nil?

      ThreadMessage.for_threads(kase.threads.to_a).find_by(id: asked)&.id
    end

    def expiry
      return nil unless NEEDS_EXPIRY.include?(type_key)

      said = params[:expires_on].to_s.strip
      return nil if said.blank?

      Date.strptime(said, "%Y-%m-%d").end_of_day
    rescue Date::Error
      nil
    end

    def channel
      return {} unless TAKES_CHANNEL.include?(type_key)
      return {} if channel_id.blank?

      { "channel_id" => channel_id }
    end
  end
end
