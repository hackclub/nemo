module Fd
  class MemberRecord
    Mark = Struct.new(:case_id, :at, :tone, :label, keyword_init: true)

    TONES = {
      "open" => "open",
      "done" => "action taken",
      "clear" => "resolved, no action",
      "in" => "logged, not the subject"
    }.freeze

    def initialize(user_id)
      @user_id = user_id
    end

    attr_reader :user_id

    def subject_cases
      @subject_cases ||= Case.with_subject(user_id)
        .includes(:subjects, :assignees).oldest_first.to_a
    end

    def logged_cases
      @logged_cases ||= Case.where(id: logged_case_ids)
        .includes(:participants, :assignees).oldest_first.to_a
    end

    def people_named
      [user_id] +
        subject_cases.flat_map { |kase| kase.subject_user_ids + kase.assignee_user_ids } +
        logged_cases.flat_map(&:assignee_user_ids) +
        actions.flat_map { |action| [action.decided_by, action.performed_by, action.reversed_by] } +
        notes.map(&:author) +
        notes.flat_map { |note| Mentions.ids(note.body) }
    end

    def actions
      @actions ||= Action.for_target(user_id).to_a
    end

    def notes
      @notes ||= Note.for_subject(user_id).visible.recent_first.to_a
    end

    def open_case
      subject_cases.find { |kase| !kase.resolved? }
    end

    def priors
      @priors ||= Case.prior_count(user_id, within: Case::PRIOR_WINDOW)
    end

    def reversed_actions
      actions.count(&:reversed?)
    end

    def anything?
      subject_cases.any? || logged_cases.any?
    end

    def first_case_at
      spread.first&.opened_at
    end

    def last_case_at
      spread.last&.opened_at
    end

    def spine
      span = seconds_covered
      spread.map do |kase|
        at = kase.opened_at
        Mark.new(
          case_id: kase.id,
          at: at,
          tone: tone_for(kase),
          label: span.zero? ? 50 : (((at - first_case_at) / span) * 100).round(1)
        )
      end
    end

    def quiet_months
      return nil if spread.size < 2

      gaps = spread.each_cons(2).map { |before, after| after.opened_at - before.opened_at }
      months = (gaps.max / 30.days).floor
      months >= 3 ? months : nil
    end

    private

    def spread
      @spread ||= (subject_cases + logged_cases).uniq(&:id).sort_by(&:opened_at)
    end

    def seconds_covered
      return 0 if spread.size < 2

      spread.last.opened_at - spread.first.opened_at
    end

    def logged_case_ids
      @logged_case_ids ||= CaseParticipant.where(user_id: user_id)
        .where.not(role: "subject").distinct.pluck(:case_id)
    end

    def tone_for(kase)
      return "in" unless subject_cases.include?(kase)
      return "open" unless kase.resolved?

      acted_on.include?(kase.id) ? "done" : "clear"
    end

    def acted_on
      @acted_on ||= Action.where(case_id: spread.map(&:id)).distinct.pluck(:case_id).to_set
    end
  end
end
