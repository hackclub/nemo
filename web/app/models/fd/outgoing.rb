module Fd
  class Outgoing
    Sent = Struct.new(:queued, :problem, keyword_init: true)

    def self.queue(kase, said, mode:, by:)
      conversation = IntakeConversation.for_case(kase.id).open_ones.first
      problem = objection(conversation, said)
      return Sent.new(problem: problem) if problem

      Sent.new(queued: IntakeOutbox.create!(conversation_id: conversation.id, kind: "reply",
        body: said, mode: mode, requested_by: by))
    end

    def self.objection(conversation, said)
      return "write something before sending it" if said.blank?
      if said.length > IntakeOutbox::MAX_LENGTH
        return "that is too long to send, keep it under #{IntakeOutbox::MAX_LENGTH} characters"
      end
      return "there is nobody to reply to on this case" if conversation.nil?
      return "that conversation is closed, so nothing can be sent" if conversation.closed?

      nil
    end
  end
end
