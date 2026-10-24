module Fd
  class ChatLogsController < BaseController
    permit "case.read"

    def show
      @case = Case.find(params[:case_id])
      family = @case.family_ids
      load_thread(family)
      @conversation_messages = IntakeMessage.tail(conversation_ids)
      @queued_replies = if @conversation
        IntakeOutbox.where(conversation_id: @conversation.id, sent_at: nil).oldest_first.to_a
      else
        []
      end
      @chat = CaseChat.tail(family, hidden_threads: @hidden_threads)
      @earlier_count = CaseChat.earlier_than(family, @chat.size, hidden_threads: @hidden_threads) +
        [IntakeMessage.count_for(conversation_ids) - @conversation_messages.size, 0].max
      load_rendering

      respond_to do |format|
        format.html { render layout: false }
        format.turbo_stream { changes_since(params[:since]) }
      end
    end

    def earlier
      @case = Case.find(params[:case_id])
      family = @case.family_ids
      load_thread(family)
      @conversation_messages = IntakeMessage.before(conversation_ids,
        IntakeMessage.find_by(id: params[:message_before], conversation_id: conversation_ids))
      @queued_replies = []
      @chat = CaseChat.before(family, CaseChat.find_by(id: params[:chat_before], case_id: family),
        hidden_threads: @hidden_threads)
      load_rendering

      render layout: false
    end

    private

    def load_thread(family)
      reports = CaseReport.where(case_id: family).oldest_first.to_a
      @root_chat = CaseChat.root_for(@case, family) if reports.empty?
      @named_reporters = reports.reject(&:anonymous?).map(&:reporter_user_id)
      @thread = reports.find { |report| report.id == params[:thread].to_i } || reports.last
      @reports = [@thread].compact
      @hidden_threads = CaseReport.threads_besides(reports, @thread)
      @conversation = IntakeConversation.for_case(family).find_by(report_id: @thread&.id)
    end

    def conversation_ids
      [@conversation&.id].compact
    end

    def load_rendering
      @cited_shares = IntakeShare.for_messages(@conversation_messages.map(&:id))
      @channels = ChannelNames.for(cited.map(&:source_channel_id).compact +
        ChatChannels.ids(@chat, @conversation_messages, @queued_replies, @reports))
      @names = Names.for(people_ids)
      @emoji = ChatEmoji.for(@chat, @conversation_messages, @queued_replies, @reports)
    end

    def cited
      (@cited_shares || {}).values.flatten
    end

    def people_ids
      user_ids = @named_reporters + @reports.map(&:closed_by) +
        @conversation_messages.map(&:sent_by) + cited.map(&:source_author_user_id) +
        @queued_replies.map(&:requested_by) + @chat.map(&:author_user_id) + [@case.opened_by] +
        ChatPeople.ids(@chat, @conversation_messages, @queued_replies, @reports)
      return user_ids if @reports.any?(&:anonymous?)

      user_ids + @conversation_messages.map(&:author_user_id)
    end

    def changes_since(since)
      @version = ChatVersion.for(@case.id)
      return head :no_content if since == @version

      previous_parts = ChatVersion.parse(since)
      @sent_ids = []
      return @everything = true if previous_parts.nil?

      current_parts = ChatVersion.parts(@case.id)
      return head :reset_content if current_parts.zip(previous_parts).any? { |current, previous| current.count < previous.count }

      previous_chat, previous_messages, previous_queued = previous_parts
      @chat_changed = @chat.select { |line| changed_since?(line, previous_chat, :posted_at, :edited_at, :deleted_at) }
      @messages_changed = @conversation_messages.select { |message| changed_since?(message, previous_messages, :posted_at, :edited_at, :deleted_at) }
      @queued_replies_changed = @queued_replies.select { |row| changed_since?(row, previous_queued, :requested_at, :sent_at, :failed_at) }
      @sent_ids = sent_since(previous_queued)

      head :no_content if [@chat_changed, @messages_changed, @queued_replies_changed, @sent_ids].all?(&:empty?)
    end

    def changed_since?(row, previous, *columns)
      row.id > previous.max_id ||
        ChatVersion.stamp(*columns.map { |column| row.public_send(column) }) >= previous.stamp
    end

    def sent_since(previous)
      return [] if @conversation.nil?

      IntakeOutbox.where(conversation_id: @conversation.id).where.not(sent_at: nil)
        .where(sent_at: previous.cutoff..).pluck(:id)
    end
  end
end
