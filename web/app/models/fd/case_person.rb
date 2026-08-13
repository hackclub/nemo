module Fd
  class CasePerson
    def self.for(person, kase:, actions:, notes:)
      return nil if person.nil?

      new(person, kase, actions, notes)
    end

    attr_reader :person, :actions

    def initialize(person, kase, actions, notes)
      @person = person
      @kase = kase
      @actions = actions.select { |action| action.target_user_id == person.user_id }
      @notes = notes
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

    def notes_naming
      @notes_naming ||= @notes.select { |note| Mentions.ids(note.body).include?(user_id) }
    end

    def notes_total
      @notes.size
    end

    def priors
      @priors ||= Case.prior_count(user_id, within: Case::PRIOR_WINDOW, before: @kase.opened_at)
    end

    def cases_ever
      @cases_ever ||= CaseParticipant.where(user_id: user_id).distinct.count(:case_id)
    end
  end
end
