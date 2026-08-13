module Fd
  class MemberTimeline
    Entry = Struct.new(:at, :title, :kind, :mark, :chips, :detail, :said, :case_id,
      keyword_init: true)

    KINDS = {
      "all" => "All",
      "subject" => "As subject",
      "logged" => "Logged in",
      "actions" => "Actions"
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
      all = case_entries + logged_entries + action_entries
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
          kind: "subject",
          mark: "own",
          chips: ["subject", outcome_of(kase)].compact,
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
            kind: "logged",
            mark: "in",
            chips: [person.role, outcome_of(kase)].compact,
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
            mark: "act",
            chips: action_chips(action),
            detail: action_detail(action),
            case_id: action.case_id
          )
        ]

        if action.reversed?
          list << Entry.new(
            at: action.reversed_at,
            title: "#{FdHelper::ACTION_LABELS.fetch(action.type_key, action.type_key)} reversed",
            kind: "actions",
            mark: "act",
            chips: ["undone"],
            detail: ["case #{action.case_id}", action.reversal_reason,
                     "by #{names[action.reversed_by]}"].compact.join(" · "),
            case_id: action.case_id,
          )
        end

        list
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

    def action_chips(action)
      chips = []
      chips << "expires #{action.expires_at.strftime('%b %-d')}" if action.expires?
      chips << "reversed" if action.reversed?
      chips
    end

    def action_detail(action)
      parts = ["case #{action.case_id}"]
      channel = action.details.is_a?(Hash) ? action.details["channel_id"] : nil
      parts << "in #{channel}" if channel
      parts << "decided by #{names[action.decided_by]}"
      unless action.performed_by_decider?
        parts << "performed by #{performer(action.performed_by)}"
      end
      parts.join(" · ")
    end

    def performer(user_id)
      user_id == "UMNEMOSYNE" ? "Mnemosyne" : names[user_id]
    end
  end
end
