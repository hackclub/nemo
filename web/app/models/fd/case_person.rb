module Fd
  class CasePerson
    def self.for(person, kase:, actions:, notes:, messages: [])
      return nil if person.nil?

      new(person, kase, actions, notes, messages)
    end

    attr_reader :person, :actions, :messages

    def initialize(person, kase, actions, notes, messages = [])
      @person = person
      @kase = kase
      @actions = actions.select { |action| action.target_user_id == person.user_id }
      @notes = notes
      @messages = messages.select { |message| message.author_user_id == person.user_id }
    end

    def threads_spoken_in
      messages.map { |message| [message.channel_id, message.thread_ts] }.uniq.size
    end

    def user_id
      person.user_id
    end

    def live_actions
      actions.reject(&:reversed?)
    end

    def reversed_actions
      actions.count(&:reversed?)
    end

    def priors
      @priors ||= Case.prior_count(user_id, within: Case::PRIOR_WINDOW, before: @kase.opened_at)
    end

    def cases_ever
      @cases_ever ||= CaseParticipant.where(user_id: user_id).distinct.count(:case_id)
    end

    Earlier = Struct.new(:kase, :counts, :why, :actions, keyword_init: true)

    def earlier_cases
      @earlier_cases ||= Case
        .where(id: CaseParticipant.where(user_id: user_id).select(:case_id))
        .where.not(id: @kase.id)
        .where(opened_at: ...@kase.opened_at)
        .includes(:actions, :subjects)
        .order(opened_at: :desc)
        .map { |other| weigh(other) }
    end

    private

    def weigh(other)
      aimed = other.actions.select { |action| action.target_user_id == user_id }
      why = excuse(other, aimed)
      Earlier.new(kase: other, actions: aimed, why: why, counts: why.nil?)
    end

    def excuse(other, aimed)
      return "logged, not the subject" unless other.subject_user_ids.include?(user_id)
      return "still open" if other.resolved_at.nil?
      return "nothing was done to them" if aimed.empty?
      return "the action was reversed" if aimed.all?(&:reversed?)
      return "outside 12 months" if other.resolved_at < @kase.opened_at - Case::PRIOR_WINDOW

      nil
    end
  end
end
