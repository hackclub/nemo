module Fd
  class CaseChatBroadcast
    def self.of(case_id)
      new(case_id).call
    end

    def self.tag(case_id, version: ChatVersion.for(case_id))
      %(<turbo-stream action="reload_frame" target="chat-log-#{case_id}" version="#{version}">) \
        .concat("</turbo-stream>").html_safe
    end

    def initialize(case_id)
      @case_id = case_id
    end

    def call
      return unless Case.exists?(id: @case_id)

      # the changed record's own case_id may be a case folded into a family the
      # viewer has open under its root - ChatVersion/ChatLogsController are already
      # family-aware, so it is enough to also reach the root's own stream
      streamed_to.each do |target_id|
        Turbo::StreamsChannel.broadcast_stream_to("case_#{target_id}_chat",
          content: self.class.tag(target_id))
      end
    end

    private

    def streamed_to
      [@case_id, Case.root_for(@case_id)].uniq
    end
  end
end
