module Fd
  class CaseTimeline
    Entry = Struct.new(:at, :title, :mark, :chips, :detail, :said, keyword_init: true)

    def self.for(kase, reports:, actions:, notes:, participants: [])
      new(kase, reports:, actions:, notes:, participants:).entries
    end

    def initialize(kase, reports:, actions:, notes:, participants: [])
      @case = kase
      @reports = reports
      @actions = actions
      @notes = notes
      @participants = participants
    end

    def entries
      (report_entries + case_entries + action_entries + note_entries)
        .compact.sort_by { |entry| [entry.at, entry.title] }
    end

    private

    attr_reader :reports, :actions, :notes, :participants

    def kase = @case

    def role_of(user_id)
      participants.find { |person| person.user_id == user_id }&.role
    end

    def subject_user_ids
      @subject_user_ids ||= participants.select { |person| person.role == "subject" }
        .map(&:user_id)
    end

    def report_entries
      reports.map do |report|
        Entry.new(
          at: report.received_at,
          title: "Report received",
          mark: "intake",
          chips: report.anonymous? ? ["anonymous"] : [],
          detail: report_detail(report),
          said: report.body,
        )
      end
    end

    def report_detail(report)
      parts = []
      unless report.anonymous?
        role = role_of(report.reporter_user_id)
        who = "from #{report.reporter_label}"
        who += ", who was involved" if role == "involved"
        parts << who
      end
      parts << "via #{report.source_app}"
      parts << (report.replied? ? "replied in #{span(report.reply_latency)}" : "no reply yet")
      parts << "told the outcome: not yet" unless report.told_of_outcome?
      parts.join(" · ")
    end

    def case_entries
      list = [
        Entry.new(
          at: kase.opened_at,
          title: "Case opened",
          mark: "owner",
          chips: [],
          detail: opened_detail,
        ),
      ]

      if kase.claimed?
        list << Entry.new(
          at: kase.claimed_at,
          title: "Assigned",
          mark: "owner",
          chips: [],
          detail: "@#{kase.claimed_by} · #{span(kase.claimed_at - kase.opened_at)} after opening",
        )
      end

      if kase.resolved?
        list << Entry.new(
          at: kase.resolved_at,
          title: "Resolved",
          mark: "owner",
          chips: [kase.resolution.tr("_", " ")],
          detail: resolved_detail,
          said: kase.member_note,
        )
      end

      list
    end

    def opened_detail
      parts = ["by @#{kase.opened_by}"]
      parts << "no subject set" if subject_user_ids.empty?
      context = kase.subject_context
      if context.is_a?(Hash) && context["priors"]
        parts << "at that moment: #{pluralize(context['priors'], 'prior')}"
      end
      parts.join(" · ")
    end

    def resolved_detail
      parts = ["by @#{kase.claimed_by || kase.opened_by}"]
      parts << "#{span(kase.resolved_at - kase.opened_at)} after opening"
      parts << "the member was not told" if kase.member_note.blank?
      parts.join(" · ")
    end

    def action_entries
      actions.flat_map do |action|
        entries = [
          Entry.new(
            at: action.performed_at,
            title: action_title(action),
            mark: "action",
            chips: action_chips(action),
            detail: action_detail(action),
          ),
        ]

        if action.reversed?
          entries << Entry.new(
            at: action.reversed_at,
            title: "#{action_title(action)} reversed",
            mark: "action",
            chips: [],
            detail: ["by @#{action.reversed_by}", action.reversal_reason].compact.join(" · "),
          )
        end

        entries
      end
    end

    def action_title(action)
      FdHelper::ACTION_LABELS.fetch(action.type_key, action.type_key.tr("_", " ").capitalize)
    end

    def action_chips(action)
      chips = []
      chips << "expires #{action.expires_at.strftime('%b %-d')}" if action.expires?
      chips << "reversed" if action.reversed?
      chips
    end

    def action_detail(action)
      parts = []
      parts << "on @#{action.target_user_id}" unless subject_user_ids.include?(action.target_user_id)
      parts << "decided by @#{action.decided_by}"
      unless action.performed_by_decider?
        parts << "performed by #{performer(action.performed_by)}"
      end
      channel = action.details.is_a?(Hash) ? action.details["channel_id"] : nil
      parts << "in #{channel}" if channel
      parts.join(" · ")
    end

    def performer(user_id)
      user_id == "UMNEMOSYNE" ? "Mnemosyne" : "@#{user_id}"
    end

    def note_entries
      notes.map do |note|
        Entry.new(
          at: note.created_at,
          title: "Note added",
          mark: "note",
          chips: note.standing? ? ["about @#{note.subject_user_id}"] : [],
          detail: "by @#{note.author}",
          said: note.body,
        )
      end
    end

    def span(seconds)
      seconds = seconds.to_i
      return "#{(seconds / 86_400)} days" if seconds >= 172_800
      return "a day" if seconds >= 86_400
      return "#{(seconds / 3600)} hours" if seconds >= 7200
      return "an hour" if seconds >= 3600
      return "#{(seconds / 60)} minutes" if seconds >= 120

      "a minute"
    end

    def pluralize(count, word)
      "#{count} #{count == 1 ? word : word.pluralize}"
    end
  end
end
