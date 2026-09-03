module Fd
  class ChatVersion
    def self.for(case_id)
      family = Case.family_of(case_id)
      conversations = IntakeConversation.for_case(family).unscope(:order).select(:id)

      [
        stamp(CaseChat.where(case_id: family), "said_at, edited_at, deleted_at"),
        stamp(IntakeMessage.where(conversation_id: conversations), "posted_at, edited_at, deleted_at"),
        stamp(IntakeOutbox.where(conversation_id: conversations), "requested_at, sent_at, failed_at")
      ].join("-")
    end

    def self.stamp(rows, columns)
      count, latest = rows.pick(Arel.sql("count(*), max(greatest(#{columns}))"))
      "#{count}.#{latest ? (latest.to_f * 1000).to_i : 0}"
    end
  end
end
