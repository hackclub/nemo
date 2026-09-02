module Fd
  class ChatLogsController < BaseController
    permit "case.read"

    def show
      @case = Case.find(params[:case_id])
      family = @case.family_ids
      reports = CaseReport.where(case_id: family).oldest_first.to_a
      @thread = reports.find { |report| report.id == params[:thread].to_i } || reports.last
      @reports = [@thread].compact
      conversation = IntakeConversation.for_case(family).find_by(report_id: @thread&.id)
      @conversation_said = IntakeMessage.tail([conversation&.id].compact)
      @queued = if conversation
        IntakeOutbox.where(conversation_id: conversation.id, sent_at: nil).oldest_first.to_a
      else
        []
      end
      @chat = CaseChat.tail(family)
      @earlier_chat = CaseChat.earlier_than(family, @chat.size)
      @names = Names.for(said_by)

      render layout: false
    end

    private

    def said_by
      named = @reports.map(&:reporter_user_id) + @reports.map(&:closed_by) +
        @conversation_said.map(&:sent_by) +
        @queued.map(&:requested_by) + @chat.map(&:author_user_id) + [@case.opened_by]
      return named if @reports.any?(&:anonymous?)

      named + @conversation_said.map(&:author_user_id)
    end
  end
end
