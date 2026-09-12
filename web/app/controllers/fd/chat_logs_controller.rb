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
      @chat_limit = [params[:limit].to_i, CaseChat::SHOWN].max
      @conversation_said = IntakeMessage.tail([@conversation&.id].compact, limit: @chat_limit)
      @queued = if @conversation
        IntakeOutbox.where(conversation_id: @conversation.id, sent_at: nil).oldest_first.to_a
      else
        []
      end
      @chat = CaseChat.tail(family, limit: @chat_limit)
      @earlier_chat = CaseChat.earlier_than(family, @chat.size)
      @earlier_said = IntakeMessage.earlier_than([@conversation&.id].compact, @conversation_said.size)
      @names = Names.for(said_by)
      @version = ChatVersion.for(@case.id)

      respond_to do |format|
        format.html { render layout: false }
        # a `limit` request (load earlier) always wants the full current window
        # rendered, same as show.turbo_stream.erb already does by default; only a
        # `since` catch-up poll needs changes_since's no-content/reset short-circuits
        format.turbo_stream { changes_since(params[:since]) unless params[:limit].present? }
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
      return head :no_content if since == @version

      had = ChatVersion.parse(since)
      return if had.nil?

      now = ChatVersion.parts(@case.id)
      return head :reset_content if now.zip(had).any? { |here, there| here.count < there.count }

      # the template always renders the full current tail (see replace_chat), so this
      # only has to decide whether anything changed at all, not compute the delta
      chat_had, said_had, queued_had = had
      changed = @chat.any? { |line| moved?(line, chat_had, :said_at, :edited_at, :deleted_at) } ||
        @conversation_said.any? { |one| moved?(one, said_had, :posted_at, :edited_at, :deleted_at) } ||
        @queued.any? { |row| moved?(row, queued_had, :requested_at, :sent_at, :failed_at) } ||
        sent_since(queued_had).any?

      head :no_content unless changed
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
