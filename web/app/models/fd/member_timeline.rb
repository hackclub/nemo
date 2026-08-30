module Fd
  class MemberTimeline
    Entry = Struct.new(:at, :title, :kind, :word, :who, :mark, :state, :detail, :said, :case_id,
      :ref, keyword_init: true)

    KINDS = {
      "all" => "Everything",
      "cases" => "Cases",
      "actions" => "Actions",
      "notes" => "Notes"
    }.freeze

    TABS = {
      "all" => "Record",
      "cases" => "Cases",
      "actions" => "Actions",
      "notes" => "Notes"
    }.freeze

    def self.for(record, names: Names.none, only: "all")
      new(record, names).entries(only)
    end

    def initialize(record, names)
      @record = record
      @names = names
    end

    def entries(only = "all")
      wanted = KINDS.key?(only) ? only : "all"
      all = case_entries + logged_entries + action_entries + note_entries
      all = all.select { |entry| entry.kind == wanted } unless wanted == "all"
      all.sort_by { |entry| [-entry.at.to_i, -entry.case_id.to_i] }
    end

    private

    attr_reader :record, :names

    def case_entries
      record.subject_cases.map do |kase|
        Entry.new(
          at: kase.opened_at,
          title: "Case #{kase.id} opened",
          kind: "cases",
          word: "case",
          who: kase.assignee_user_ids.first,
          mark: "own",
          state: outcome_of(kase),
          detail: case_detail(kase),
          case_id: kase.id,
        )
      end
    end

    def logged_entries
      record.logged_cases.flat_map do |kase|
        kase.participants.select { |person| person.user_id == record.user_id }.map do |person|
          Entry.new(
            at: kase.opened_at,
            title: "Case #{kase.id}",
            kind: "cases",
            word: "case",
            who: kase.assignee_user_ids.first,
            mark: "in",
            state: "logged in",
            detail: logged_detail(kase, person),
            case_id: kase.id,
          )
        end
      end
    end

    def action_entries
      record.actions.flat_map do |action|
        list = [
          Entry.new(
            at: action.performed_at,
            title: FdHelper::ACTION_LABELS.fetch(action.type_key, action.type_key.tr("_", " ")),
            kind: "actions",
            word: "action",
            who: action.decided_by,
            mark: "act",
            state: action.reversed? ? "reversed" : "standing",
            detail: action_detail(action),
            case_id: action.case_id
          )
        ]

        if action.reversed?
          list << Entry.new(
            at: action.reversed_at,
            title: "#{FdHelper::ACTION_LABELS.fetch(action.type_key, action.type_key)} reversed",
            kind: "actions",
            word: "reversal",
            who: action.reversed_by,
            mark: "act",
            state: "reversed",
            detail: ["case #{action.case_id}", action.reversal_reason,
                     "by #{names[action.reversed_by]}"].compact.join(" · "),
            case_id: action.case_id,
          )
        end

        list
      end
    end

    def note_entries
      record.notes.map do |note|
        Entry.new(
          at: note.created_at,
          title: "Note",
          kind: "notes",
          word: "note",
          who: note.author,
          mark: "note",
          state: names[note.author],
          detail: nil,
          said: note.body,
          case_id: nil,
          ref: note
        )
      end
    end

    def outcome_of(kase)
      return "open" unless kase.resolved?

      kase.resolution.to_s.tr("_", " ")
    end

    def case_detail(kase)
      parts = [kase.category_key&.tr("_", " ")]
      others = kase.subject_user_ids - [record.user_id]
      parts << "with #{names.list(others)}" if others.any?
      parts << if kase.assigned?
        "assigned to #{names.list(kase.assignee_user_ids)}"
      else
        "unassigned"
      end
      parts.compact.join(" · ")
    end

    def logged_detail(kase, person)
      parts = [kase.category_key&.tr("_", " "), person.detail]
      parts << "they were not the subject"
      parts.compact.join(" · ")
    end

    def action_detail(action)
      parts = ["case #{action.case_id}"]
      channel = action.details.is_a?(Hash) ? action.details["channel_id"] : nil
      parts << "in #{channel}" if channel
      parts << "by #{names[action.decided_by]}"
      parts << "lifts #{action.expires_at.strftime('%-d %b')}" if action.expires?
      parts << action.reason if action.reason.present?
      parts.join(" · ")
    end
  end
end
