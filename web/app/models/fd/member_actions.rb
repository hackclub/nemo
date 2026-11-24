module Fd
  class MemberActions
    Entry = Struct.new(:at, :label, :tone, :details, :states, :category, :reason, :by, :case_id, :thread_url,
      keyword_init: true)

    GUARD_TONES = { MemberGuard::DEACTIVATION => "crit", MemberGuard::SHUSH => "orange",
                    MemberGuard::CHANNEL_BAN => "orange" }.freeze

    def self.for(record)
      new(record).entries
    end

    def initialize(record)
      @record = record
    end

    def entries
      list = action_entries + guard_entries + removal_entries
      list.each_with_index.sort_by { |entry, index| [-entry.at.to_i, index] }.map(&:first)
    end

    private

    attr_reader :record

    def action_entries
      record.actions.map do |action|
        Entry.new(
          at: action.performed_at, label: label_for(action.type_key), tone: action_tone(action),
          details: action_details(action), states: action_states(action),
          category: category_for(action.category_key.presence || cases[action.case_id]&.category_key),
          reason: action.reason, by: action.decided_by, case_id: action.case_id,
          thread_url: thread_url(action.case_id)
        )
      end
    end

    def guard_entries
      record.guards_on_no_case.map do |guard|
        Entry.new(
          at: guard.opened_at, label: label_for(guard.kind), tone: GUARD_TONES.fetch(guard.kind, "plain"),
          details: guard_details(guard), states: guard_states(guard), category: nil,
          reason: guard.reason, by: guard.opened_by, case_id: nil, thread_url: nil
        )
      end
    end

    def removal_entries
      record.photo_removals.map do |removal|
        Entry.new(
          at: removal.finished_at, label: removal.failed? ? "Pfp removal failed" : "Pfp removed", tone: "plain",
          details: [], states: [], category: nil, reason: removal.reason, by: removal.asked_by,
          case_id: nil, thread_url: nil
        )
      end
    end

    def label_for(key)
      Action::LABELS.fetch(key) { key.tr("_", " ").capitalize }
    end

    def category_for(key)
      key.present? ? Case.category_label(key) : nil
    end

    def action_tone(action)
      return "muted" if action.reversed?
      return "warn" if action.type_key == "warning"

      GUARD_TONES.fetch(Action.guard_kind(action.type_key).to_s, "plain")
    end

    def action_details(action)
      parts = []
      channel = action.details.is_a?(Hash) ? action.details["channel_id"] : nil
      parts << "in #{channels[channel]}" if channel
      if action.expires? && !action.reversed?
        parts << "#{action.expired? ? 'Ended' : 'Ends'} #{ShortDate.ending(action.expires_at)}"
      end
      parts
    end

    def action_states(action)
      states = []
      states << "Reversed #{ShortDate.for(action.reversed_at)}" if action.reversed?
      states << "Cancelled" if action.guard&.cancelled?
      states
    end

    def guard_details(guard)
      parts = []
      parts << "in #{channels[guard.channel_id]}" if guard.channel_scoped?
      parts << "Starts #{ShortDate.starting(guard.starts_at)}" if guard.starts_at && guard.scheduled?
      parts << "Ends #{ShortDate.ending(guard.expires_at)}" if guard.expires_at && !guard.lifted_at
      parts
    end

    def guard_states(guard)
      return ["Cancelled #{ShortDate.for(guard.cancelled_at)}"] if guard.cancelled_at
      return [] unless guard.lifted_at

      ["#{guard.deactivation? ? 'Reactivated' : 'Lifted'} #{ShortDate.for(guard.lifted_at)}"]
    end

    def case_ids
      @case_ids ||= record.actions.map(&:case_id).uniq
    end

    def cases
      @cases ||= Case.where(id: case_ids).index_by(&:id)
    end

    def internal_threads
      @internal_threads ||= CaseThread.visible.internal.where(case_id: case_ids).primary_first.group_by(&:case_id)
    end

    def channels
      @channels ||= ChannelNames.for(
        record.actions.filter_map { |action| action.details["channel_id"] if action.details.is_a?(Hash) } +
        record.guards_on_no_case.map(&:channel_id)
      )
    end

    def thread_url(case_id)
      kase = cases[case_id]
      thread_ts = kase&.card_thread_ts.presence || kase&.card_ts.presence
      return SlackLink.url_for(kase.card_channel_id, thread_ts) if kase&.card_channel_id.present? && thread_ts

      thread = internal_threads[case_id]&.first
      SlackLink.url_for(thread.channel_id, thread.thread_ts) if thread
    end
  end
end
