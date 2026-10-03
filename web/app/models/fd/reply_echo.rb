module Fd
  class ReplyEcho
    def self.flush_pending(case_id)
      thread_ts = SlackPost.thread_for(case_id)
      return 0 if thread_ts.nil? || SlackPost.room.nil?

      waiting(case_id).count { |queued| carry(queued, thread_ts) }
    end

    def self.waiting(case_id)
      IntakeOutbox.where(echoed_at: nil).where.not(sent_at: nil)
        .where(conversation_id: IntakeConversation.for_case(case_id).select(:id))
        .order(:sent_at)
    end

    def self.carry(queued, thread_ts)
      grant = StaffSlack.held_by(queued.requested_by)
      return false if grant.nil?
      return false unless claim(queued)

      answer = Slack::Chat.post_message(token: grant.user_token, channel: SlackPost.room,
        thread_ts: thread_ts, text: payload_for(queued))
      return release_after_error(queued, grant, answer["error"]) unless answer["ok"]

      queued.update!(echoed_ts: answer["ts"], echoed_as: "user")
      grant.used!
      true
    rescue Slack::Chat::UnavailableError => failure
      release_after_error(queued, grant, failure.message)
    rescue StandardError
      release(queued)
      raise
    end

    def self.payload_for(queued)
      mark = queued.mode == "signed" ? "?" : "~?"
      "#{mark}#{SlackPost.escape_markup(queued.body)}"
    end

    def self.claim(queued)
      IntakeOutbox.where(id: queued.id, echoed_at: nil)
        .update_all(echoed_at: Time.current) == 1
    end

    def self.release_after_error(queued, grant, why)
      grant&.record_error!(why)
      release(queued)
    end

    def self.release(queued)
      IntakeOutbox.where(id: queued.id, echoed_ts: nil).update_all(echoed_at: nil)
      false
    end
  end
end
