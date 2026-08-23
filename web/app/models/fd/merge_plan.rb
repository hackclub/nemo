module Fd
  class MergePlan
    def self.for(from, into, keeper: nil)
      new(from, into, keeper: keeper)
    end

    def initialize(from, into, keeper: nil)
      @from = from
      @into = into
      @asked = keeper
    end

    attr_reader :from, :into

    def keeper
      @keeper ||= [from, into].find { |one| one.id == @asked.to_i } ||
        [from, into].min_by(&:opened_at)
    end

    def folded
      @folded ||= keeper == from ? into : from
    end

    def survives
      [
        ["The case number", "##{keeper.id}, opened #{keeper.opened_at.strftime('%-d %b')}"],
        ["Reports", "#{reports} kept, each with its own reporter"],
        ["Evidence threads", pluralize_word(threads, "thread")],
        ["Actions logged", pluralize_word(actions, "action")],
        ["Notes", pluralize_word(notes, "note")],
        ["Everybody logged", pluralize_word(people, "person", "people")]
      ]
    end

    def folds
      ["##{folded.id} closes as a duplicate of ##{keeper.id}",
       "Its link keeps working, and lands on ##{keeper.id}",
       holder_line].compact
    end

    def holder_line
      return nil unless folded.assigned?

      "#{folded.assignee_handles} stops holding it"
    end

    def destructive
      return nil unless folded.assigned?

      "#{folded.assignee_handles} is holding ##{folded.id}, and loses it."
    end

    def same_thread?
      shared_pairs.any?
    end

    def shared_channels
      shared_pairs.map(&:first).uniq
    end

    def reports = both { |kase| kase.reports.size }

    def threads = both { |kase| kase.threads.size }

    def actions = both { |kase| kase.actions.size }

    def notes = both { |kase| kase.notes.visible.size }

    def people
      (from.participants.map(&:user_id) + into.participants.map(&:user_id)).uniq.size
    end

    private

    def both(&block)
      block.call(from) + block.call(into)
    end

    def shared_pairs
      @shared_pairs ||= from.threads.map(&:coordinates) & into.threads.map(&:coordinates)
    end

    def pluralize_word(count, word, plural = nil)
      "#{count} #{count == 1 ? word : (plural || "#{word}s")}"
    end
  end
end
