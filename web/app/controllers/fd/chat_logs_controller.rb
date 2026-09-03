module Fd
  class ChatLogsController < BaseController
    permit "case.read"

    def show
      @case = Case.find(params[:case_id])
      family = @case.family_ids
      reports = CaseReport.where(case_id: family).oldest_first.to_a
      @thread = reports.find { |report| report.id == params[:thread].to_i } || reports.last
      @reports = [@thread].compact
      @conversation = IntakeConversation.for_case(family).find_by(report_id: @thread&.id)
      @conversation_said = IntakeMessage.tail([@conversation&.id].compact)
      @queued = if @conversation
        IntakeOutbox.where(conversation_id: @conversation.id, sent_at: nil).oldest_first.to_a
      else
        []
      end
      @chat = CaseChat.tail(family)
      @earlier_chat = CaseChat.earlier_than(family, @chat.size)
      @names = Names.for(said_by)

      respond_to do |format|
        format.html { render layout: false }
        format.turbo_stream { changes_since(params[:since]) }
      end
    end

    private

    def said_by
      named = @reports.map(&:reporter_user_id) + @reports.map(&:closed_by) +
        @conversation_said.map(&:sent_by) +
        @queued.map(&:requested_by) + @chat.map(&:author_user_id) + [@case.opened_by]
      return named if @reports.any?(&:anonymous?)

      named + @conversation_said.map(&:author_user_id)
    end

    def changes_since(since)
      @version = ChatVersion.for(@case.id)
      return head :no_content if since == @version

      had = ChatVersion.parse(since)
      @gone = []
      return @everything = true if had.nil?

      now = ChatVersion.parts(@case.id)
      return head :reset_content if now.zip(had).any? { |here, there| here.count < there.count }

      chat_had, said_had, queued_had = had
      @chat_changed = @chat.select { |line| moved?(line, chat_had, :said_at, :edited_at, :deleted_at) }
      @said_changed = @conversation_said.select { |one| moved?(one, said_had, :posted_at, :edited_at, :deleted_at) }
      @queued_changed = @queued.select { |row| moved?(row, queued_had, :requested_at, :sent_at, :failed_at) }
      @gone = sent_since(queued_had)

      head :no_content if [@chat_changed, @said_changed, @queued_changed, @gone].all?(&:empty?)
    end

    def moved?(row, had, *columns)
      row.id > had.max_id ||
        ChatVersion.stamp(*columns.map { |column| row.public_send(column) }) >= had.stamp
    end

    def sent_since(had)
      return [] if @conversation.nil?

      IntakeOutbox.where(conversation_id: @conversation.id).where.not(sent_at: nil)
        .where(sent_at: had.cutoff..).pluck(:id)
    end
  end
end
