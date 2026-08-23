module Fd
  class MergePlan
    def self.for(from, into, keeper: nil)
      new([from, into], keeper: keeper)
    end

    def self.over(cases, keeper: nil)
      new(cases, keeper: keeper)
    end

    def initialize(all, keeper: nil)
      @all = Array(all).compact.uniq(&:id)
      @asked = keeper
    end

    attr_reader :all

    def from
      all.first
    end

    def into
      all.last
    end

    def pair?
      all.size == 2
    end

    def keeper
      @keeper ||= all.find { |one| one.id == @asked.to_i } || all.min_by(&:opened_at)
    end

    def folded_cases
      @folded_cases ||= all.reject { |one| one.id == keeper.id }
    end

    def folded
      folded_cases.first
    end

    def reports = both { |kase| kase.reports.size }

    def threads = both { |kase| kase.threads.size }

    def actions = both { |kase| kase.actions.size }

    def notes = both { |kase| kase.notes.visible.size }

    def people
      all.flat_map { |kase| kase.participants.map(&:user_id) }.uniq.size
    end

    private

    def both(&block)
      all.sum(&block)
    end
  end
end
