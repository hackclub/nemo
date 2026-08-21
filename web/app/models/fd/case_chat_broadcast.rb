module Fd
  class CaseChatBroadcast
    def self.of(case_id)
      new(Case.find_by(id: case_id)).call
    end

    def initialize(kase)
      @case = kase
    end

    def call
      return if @case.nil?

      chat = CaseChat.tail(@case.id)
      reports = @case.reports.oldest_first.to_a

      Turbo::StreamsChannel.broadcast_replace_to(
        "case_#{@case.id}_chat",
        target: "chat-log-#{@case.id}",
        partial: "fd/cases/chat_log",
        locals: { kase: @case, reports: reports, chat: chat,
                  earlier: CaseChat.earlier_than(@case.id, chat.size) },
        assigns: { names: Names.for(names_in(reports, chat)) }
      )
    end

    private

    def names_in(reports, chat)
      reports.map(&:reporter_user_id) + reports.map(&:closed_by) +
        chat.map(&:author_user_id) + [@case.opened_by]
    end
  end
end
