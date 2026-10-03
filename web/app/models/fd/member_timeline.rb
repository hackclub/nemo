module Fd
  class MemberTimeline
    Entry = Struct.new(:at, :title, :kind, :word, :who, :mark, :state, :detail, :body, :case_id,
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
      @channels = ChannelNames.for(
        record.guards.map(&:channel_id) +
          record.actions.filter_map { |one| one.details["channel_id"] if one.details.is_a?(Hash) }
      )
    end

    def entries(only = "all")
      wanted = KINDS.key?(only) ? only : "all"
      all = case_entries + logged_entries + action_entries + guard_entries + note_entries
      all = all.select { |entry| entry.kind == wanted } unless wanted == "all"
      all.sort_by { |entry| [-entry.at.to_i, -entry.case_id.to_i] }
    end

    private

    attr_reader :record, :names, :channels

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
            state: action.reversed? ? "reversed" : nil,
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

    def guard_entries
      record.guards_on_no_case.flat_map do |guard|
        list = [
          Entry.new(
            at: guard.opened_at,
            title: guard_label(guard),
            kind: "actions",
            word: "action",
            who: guard.opened_by,
            mark: "act",
            state: guard.lifted_at ? "reversed" : nil,
            detail: guard_detail(guard),
            case_id: nil
          )
        ]

        if guard.lifted_at
          list << Entry.new(
            at: guard.lifted_at,
            title: "#{guard_label(guard)} lifted",
            kind: "actions",
            word: "reversal",
            who: guard.lifted_by,
            mark: "act",
            state: "reversed",
            detail: ["on no case", guard.lift_reason,
                     ("by #{names[guard.lifted_by]}" if guard.lifted_by)].compact.join(" · "),
            case_id: nil
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
          body: note.body,
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
      parts = [kase.category_key&.tr("_", " ")]
      parts << "they were not the subject"
      parts.compact.join(" · ")
    end

    def guard_label(guard)
      FdHelper::ACTION_LABELS.fetch(guard.kind, guard.kind.tr("_", " ").capitalize)
    end

    def guard_detail(guard)
      parts = ["on no case"]
      parts << "in #{channels[guard.channel_id]}" if guard.channel_scoped?
      parts << "by #{names[guard.opened_by]}"
      parts << "lifts #{guard.expires_at.strftime('%-d %b')}" if guard.expires_at
      parts << guard.reason if guard.reason.present?
      parts.join(" · ")
    end

    def action_detail(action)
      parts = ["case #{action.case_id}"]
      channel = action.details.is_a?(Hash) ? action.details["channel_id"] : nil
      parts << "in #{channels[channel]}" if channel
      parts << "by #{names[action.decided_by]}"
      parts << "lifts #{action.expires_at.strftime('%-d %b')}" if action.expires?
      parts << action.reason if action.reason.present?
      parts.join(" · ")
    end
  end
end
