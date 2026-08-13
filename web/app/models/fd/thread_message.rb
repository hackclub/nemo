module Fd
  class ThreadMessage < ApplicationRecord
    self.table_name = "fd.thread_messages"

    scope :oldest_first, -> { order(:posted_at, :message_ts) }
    scope :roots, -> { where(is_root: true) }
    scope :in_thread, ->(channel_id, thread_ts) {
      where(channel_id: channel_id, thread_ts: thread_ts)
    }

    def self.for_threads(threads)
      pairs = Array(threads).map { |thread| [thread.channel_id, thread.thread_ts] }.uniq
      return none if pairs.empty?

      where(pairs.map { "(channel_id = ? AND thread_ts = ?)" }.join(" OR "), *pairs.flatten)
        .oldest_first
    end

    def readonly?
      persisted?
    end

    def root?
      is_root
    end

    def deleted?
      deleted_at.present?
    end

    def purged?
      purged_at.present?
    end

    def edited?
      edited_at.present?
    end

    def written_by_a_person?
      author_user_id.present?
    end

    def readable?
      body.present?
    end

    def replies_held
      return nil unless root?

      ThreadMessage.in_thread(channel_id, thread_ts).where(is_root: false).count
    end
  end
end
