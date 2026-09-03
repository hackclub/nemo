module Fd
  class ChatPresence
    KEEP_FOR = 6.hours

    def self.arrive(case_id, user_id)
      change(case_id) { |here| here[user_id] = here.fetch(user_id, 0) + 1 }
    end

    def self.leave(case_id, user_id)
      change(case_id) do |here|
        left = here.fetch(user_id, 0) - 1
        left.positive? ? here[user_id] = left : here.delete(user_id)
      end
    end

    def self.here(case_id)
      Rails.cache.read(key(case_id)) || {}
    end

    def self.change(case_id)
      here = self.here(case_id).dup
      yield here
      Rails.cache.write(key(case_id), here, expires_in: KEEP_FOR)
      broadcast(case_id, here.keys)
      here
    end

    def self.broadcast(case_id, user_ids)
      Turbo::StreamsChannel.broadcast_replace_to("case_#{case_id}_chat",
        target: "chat-presence-#{case_id}", partial: "fd/cases/presence",
        locals: { case_id: case_id, user_ids: user_ids, names: Names.for(user_ids) })
    end

    def self.key(case_id)
      "chat_presence/#{case_id}"
    end
  end
end
