module Fd
  class MemberStanding
    WEIGHT = Action::WORST_FIRST

    def initialize(record, at: Time.current)
      @record = record
      @at = at
    end

    attr_reader :record, :at

    def priors
      record.priors
    end

    def in_force
      @in_force ||= record.actions.select { |action| action.active?(at) }
        .sort_by { |action| [weight_of(action), -action.performed_at.to_i] }
    end

    def worst
      in_force.first
    end

    def reversed
      record.reversed_actions
    end

    def open_case
      record.open_case
    end

    def holders
      open_case&.assignee_user_ids || []
    end

    def held_by
      holders.first
    end

    def cases
      record.subject_cases.size
    end

    def logged_in
      record.logged_cases.size
    end

    def actions
      record.actions.size
    end

    def clean?
      !record.anything? && record.actions.empty?
    end

    def anything_in_force?
      in_force.any?
    end

    def lifts_at
      worst&.expires_at
    end

    private

    def weight_of(action)
      WEIGHT.index(action.type_key) || WEIGHT.size
    end
  end
end
