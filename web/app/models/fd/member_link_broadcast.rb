module Fd
  class MemberLinkBroadcast
    LIST = "*".freeze
    LIST_STREAM = "member_links".freeze
    LIST_FRAME = "member-links-list".freeze

    def self.stream(user_id) = "member_#{user_id}_links"

    def self.frame(user_id) = "member-links-#{user_id}"

    def self.of(payload)
      return list if payload == LIST

      user_id = MemberGuardBroadcast.subject_from(payload)
      member(user_id) if user_id
    end

    def self.member(user_id)
      Turbo::StreamsChannel.broadcast_stream_to(stream(user_id), content: tag("refresh_frame", frame(user_id)))
    end

    def self.list
      Turbo::StreamsChannel.broadcast_stream_to(LIST_STREAM, content: tag("reload_frame", LIST_FRAME))
    end

    def self.tag(action, target)
      %(<turbo-stream action="#{action}" target="#{target}"></turbo-stream>).html_safe
    end
  end
end
