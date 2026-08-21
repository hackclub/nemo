module Fd
  class ChatLogsController < BaseController
    permit "case.read"

    def show
      @case = Case.find(params[:case_id])
      @reports = @case.reports.oldest_first.to_a
      conversations = IntakeConversation.for_case(@case.id).pluck(:id)
      @conversation_said = IntakeMessage.tail(conversations)
      @queued = IntakeOutbox.where(conversation_id: conversations, sent_at: nil)
        .oldest_first.to_a
      @chat = CaseChat.tail(@case.id)
      @earlier_chat = CaseChat.earlier_than(@case.id, @chat.size)
      @names = Names.for(said_by)

      render layout: false
    end

    private

    def said_by
      @reports.map(&:reporter_user_id) + @reports.map(&:closed_by) +
        @conversation_said.map(&:author_user_id) + @conversation_said.map(&:sent_by) +
        @queued.map(&:requested_by) + @chat.map(&:author_user_id) + [@case.opened_by]
    end
  end
end
