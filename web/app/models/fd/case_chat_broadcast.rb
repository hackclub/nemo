module Fd
  class CaseChatBroadcast
    def self.of(case_id)
      new(case_id).call
    end

    def self.tag(case_id)
      path = Rails.application.routes.url_helpers.fd_case_chat_log_path(case_id)
      said = %(<turbo-stream action="reload_frame" target="chat-log-#{case_id}" ) +
             %(src="#{path}"></turbo-stream>)
      said.html_safe
    end

    def initialize(case_id)
      @case_id = case_id
    end

    def call
      return unless Case.exists?(id: @case_id)

      Turbo::StreamsChannel.broadcast_stream_to("case_#{@case_id}_chat",
        content: self.class.tag(@case_id))
    end
  end
end
