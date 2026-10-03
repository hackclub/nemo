module Fd
  class SlackPost
    def self.room
      ENV["INTERNAL_LOG_CHANNEL_ID"].presence
    end

    def self.thread_for(case_id)
      CaseReport.where(case_id: case_id).where.not(forwarded_ts: nil)
        .order(:received_at).pick(:forwarded_ts)
    end

    def self.claimable?(case_id, author_user_id)
      return false if room.nil?
      return false if StaffSlack.held_by(author_user_id).nil?

      thread_for(case_id).present?
    end

    def self.carry(chat)
      grant = StaffSlack.held_by(chat.author_user_id)
      thread_ts = thread_for(chat.case_id)
      return abandon(chat, "there is nothing to send it with") if grant.nil? || thread_ts.nil?

      answer = tell(grant, thread_ts, chat.body)
      return abandon(chat, answer[:error], grant) unless answer[:ts]

      chat.update!(mirrored_ts: answer[:ts], mirrored_at: Time.current, mirrored_as: "user")
      grant.used!
      true
    end

    def self.tell(grant, thread_ts, body)
      answer = Slack::Chat.post_message(token: grant.user_token, channel: room,
        thread_ts: thread_ts, text: escape_markup(body))
      return { ts: answer["ts"] } if answer["ok"]

      { error: answer["error"].to_s.presence || "slack refused it" }
    rescue Slack::Chat::UnavailableError => failure
      { error: failure.message }
    end

    def self.abandon(chat, why, grant = nil)
      grant&.record_error!(why)
      chat.update!(mirrored_as: nil)
      false
    end

    def self.escape_markup(body)
      Mentions.split(body).map { |part|
        part.start_with?("<@") ? part : plain_text(part)
      }.join
    end

    def self.plain_text(part)
      part.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end
  end
end
