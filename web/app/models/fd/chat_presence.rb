module Fd
  class ChatPresence
    STALE_AFTER = 75.seconds
    KEEP_FOR = 10.minutes

    def self.arrive(case_id, user_id)
      change(case_id) do |here|
        seen = here.fetch(user_id, { "n" => 0 })
        here[user_id] = { "n" => seen["n"] + 1, "at" => now }
      end
    end

    def self.beat(case_id, user_id)
      change(case_id) do |here|
        seen = here.fetch(user_id, { "n" => 1 })
        here[user_id] = { "n" => seen["n"], "at" => now }
      end
    end

    def self.leave(case_id, user_id)
      change(case_id) do |here|
        left = here.fetch(user_id, { "n" => 0 })["n"] - 1
        left.positive? ? here[user_id] = { "n" => left, "at" => now } : here.delete(user_id)
      end
    end

    def self.here(case_id)
      fresh(Rails.cache.read(key(case_id)) || {}).keys
    end

    def self.change(case_id)
      before = here(case_id)
      here = fresh(Rails.cache.read(key(case_id)) || {})
      yield here
      Rails.cache.write(key(case_id), here, expires_in: KEEP_FOR)
      broadcast(case_id, here.keys) if here.keys.sort != before.sort
      here.keys
    end

    def self.fresh(entries)
      floor = now - STALE_AFTER.to_i
      entries.select { |_, seen| seen.is_a?(Hash) && seen["at"].to_i >= floor }
    end

    def self.now
      Time.current.to_i
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
