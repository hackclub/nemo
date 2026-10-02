module Fd
  class MemberGuardBroadcast
    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    def self.of(subject_id)
      new(subject_id).call
    end

    def self.stream(subject_id) = "member_#{subject_id}_standing"

    def self.frame(subject_id) = "member-standing-#{subject_id}"

    def self.subject_from(payload)
      said = payload.to_s.strip.upcase
      said if said.match?(MEMBER_ID)
    end

    def self.tag(subject_id)
      %(<turbo-stream action="reload_frame" target="#{frame(subject_id)}">)
        .concat("</turbo-stream>").html_safe
    end

    def initialize(subject_id)
      @subject_id = subject_id
    end

    def call
      Turbo::StreamsChannel.broadcast_stream_to(
        self.class.stream(@subject_id), content: self.class.tag(@subject_id)
      )
    end
  end
end
