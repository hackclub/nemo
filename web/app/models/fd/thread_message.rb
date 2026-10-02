module Fd
  class ThreadMessage < ApplicationRecord
    self.table_name = "fd.thread_messages"

    scope :oldest_first, -> { order(:posted_at, :message_ts) }

    def self.for_threads(threads)
      pairs = Array(threads).map { |thread| [thread.channel_id, thread.thread_ts] }.uniq
      return none if pairs.empty?

      where(pairs.map { "(channel_id = ? AND thread_ts = ?)" }.join(" OR "), *pairs.flatten)
        .oldest_first
    end

    def readonly?
      persisted?
    end
  end
end
