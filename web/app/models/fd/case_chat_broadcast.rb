module Fd
  class CaseChatBroadcast
    include Rails.application.routes.url_helpers

    def self.of(case_id)
      new(case_id).call
    end

    def initialize(case_id)
      @case_id = case_id
    end

    def call
      return unless Case.exists?(id: @case_id)

      Turbo::StreamsChannel.broadcast_stream_to("case_#{@case_id}_chat", content: stream)
    end

    private

    def stream
      %(<turbo-stream action="reload_frame" target="chat-log-#{@case_id}" ) +
        %(src="#{fd_case_chat_log_path(@case_id)}"></turbo-stream>)
    end
  end
end
