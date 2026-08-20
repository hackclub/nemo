module Fd
  class MemberFlags
    Flag = CaseFlags::Flag

    WINDOW = 12.months
    NOTE_SHOWN = 90

    def self.for_member(record, names: Names.none)
      new(record, names).flags
    end

    def initialize(record, names)
      @record = record
      @names = names
    end

    def flags
      [record_flag, standing_note_flag].compact
    end

    private

    def record_flag
      recent = @record.subject_cases.select { |kase| kase.opened_at >= WINDOW.ago }
      return nil if recent.empty?

      acted = recent.count { |kase| acted_on?(kase) }
      Flag.new(tone: acted.positive? ? "crit" : "mid",
        headline: "#{pluralised(recent.size)} in the last year, #{ended(acted)}.",
        detail: standing_detail)
    end

    def pluralised(count)
      count == 1 ? "One case" : "#{count} cases"
    end

    def ended(acted)
      return "none ended in action" if acted.zero?
      return "one ended in action" if acted == 1

      "#{acted} ended in action"
    end

    def standing_detail
      live = @record.actions.reject { |a| a.reversed? || a.expired? }
        .max_by(&:performed_at)
      return nil if live.nil?

      label = ACTION_WORDS.fetch(live.type_key) { live.type_key.tr("_", " ") }
      "The #{label} from #{live.performed_at.strftime('%-d %b')} still stands."
    end

    ACTION_WORDS = {
      "warning" => "warning", "shush" => "shush", "temp_ban" => "temporary ban",
      "indefinite_ban" => "indefinite ban", "perma_ban" => "permanent ban",
      "channel_ban" => "channel ban", "locked_thread" => "thread lock", "dm" => "DM"
    }.freeze

    def acted_on?(kase)
      @record.actions.any? { |a| a.case_id == kase.id && !a.reversed? }
    end

    def standing_note_flag
      note = @record.notes.first
      return nil if note.nil?

      Flag.new(tone: "mid", headline: "A standing note is on them.",
        detail: "\u201C#{note.body.to_s.truncate(NOTE_SHOWN)}\u201D " \
                "#{@names[note.author]}, #{note.created_at.strftime('%-d %b')}.")
    end
  end
end
