module Fd
  class CaseThreads
    include Enumerable

    class Attached
      def initialize(record, locked)
        @record = record
        @locked = locked
      end

      attr_reader :record

      delegate :id, :channel_id, :thread_ts, :added_by, :added_at, :kind,
        :evidence?, :internal?, to: :record

      def primary?
        record.is_primary
      end

      def locked?
        @locked
      end

      def state
        return "internal" if internal?
        return "locked" if locked?
        return "linked" if primary?

        "evidence"
      end

      def tone
        return "chip-warn" if internal? || locked?

        "chip-off"
      end
    end

    def self.for(threads, actions: [], asked: nil)
      new(threads, actions, asked)
    end

    attr_reader :chosen

    def initialize(threads, actions = [], asked = nil)
      locked = locked_channels(actions)
      @rows = threads
        .sort_by { |thread| [thread.internal? ? 0 : 1, thread.is_primary ? 0 : 1, thread.added_at] }
        .map { |thread| Attached.new(thread, locked.include?(thread.channel_id)) }
      @chosen = @rows.find { |row| row.id.to_s == asked.to_s } || @rows.first
    end

    def each(&block)
      @rows.each(&block)
    end

    def size
      @rows.size
    end

    def chosen?(row)
      row.id == @chosen&.id
    end

    private

    def locked_channels(actions)
      actions
        .select { |action| action.type_key == "locked_thread" && !action.reversed? }
        .filter_map { |action| action.details["channel_id"] }
        .to_set
    end
  end
end
