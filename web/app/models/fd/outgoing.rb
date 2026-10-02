module Fd
  class Outgoing
    Sent = Struct.new(:queued, :problem, keyword_init: true)

    GONE = "the reporter you picked is no longer open on this case, so nothing was sent. " \
           "Reload the case and pick again.".freeze

    def self.queue(conversation, said, mode:, by:, asked: false)
      problem = objection(conversation, said, asked: asked)
      return Sent.new(problem: problem) if problem

      Sent.new(queued: IntakeOutbox.create!(conversation_id: conversation.id, kind: "reply",
        body: said, mode: mode, requested_by: by))
    end

    def self.objection(conversation, said, asked: false)
      return "write something before sending it" if said.blank?
      if said.length > IntakeOutbox::MAX_LENGTH
        return "that is too long to send, keep it under #{IntakeOutbox::MAX_LENGTH} characters"
      end
      if conversation.nil?
        return asked ? GONE : "there is nobody to reply to on this case"
      end
      return "that conversation is closed, so nothing can be sent" if conversation.closed?

      nil
    end
  end
end
