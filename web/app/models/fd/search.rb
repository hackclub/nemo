module Fd
  class Search
    MIN_TERM = 2
    LIMIT = 3
    SCOPED_LIMIT = 20
    WINDOW = 90
    LEAD_IN = 30

    PREFIXES = { "@" => "member", "#" => "case", "d:" => "decision",
                 "n:" => "note", "r:" => "report" }.freeze
    SCOPES = %w[member case decision note report].freeze

    Row = Struct.new(:kind, :record, :said, keyword_init: true)
    Group = Struct.new(:key, :label, :rows, :total, keyword_init: true)

    LABELS = {
      "member" => "Members",
      "case" => "Cases",
      "decision" => "Decisions",
      "note" => "Notes",
      "report" => "Reports"
    }.freeze

    def initialize(term, scope: nil, limit: nil)
      raw = term.to_s.strip
      prefix = PREFIXES.keys.find { |mark| raw.downcase.start_with?(mark) }

      @scope = SCOPES.find { |kind| kind == scope.to_s } || (prefix && PREFIXES[prefix])
      @term = prefix ? raw[prefix.length..].to_s.strip : raw
      @limit = limit || (@scope ? SCOPED_LIMIT : LIMIT)
    end

    attr_reader :term, :scope

    def asked? = searching? || scope.present? || thread.present?

    def searching? = term.length >= MIN_TERM

    def thread
      return @thread if defined?(@thread)

      @thread = SlackLink.parse(term)
    end

    def groups
      @groups ||= asked? ? built.reject { |group| group.rows.empty? } : []
    end

    def total
      groups.sum(&:total)
    end

    def self.snippet(body, term)
      text = body.to_s.squish
      word = term.to_s.split.first.to_s
      at = word.present? ? text.downcase.index(word.downcase) : nil
      return text.truncate(WINDOW) if at.nil?

      from = [at - LEAD_IN, 0].max
      cut = text[from, WINDOW].to_s
      "#{'…' if from.positive?}#{cut}#{'…' if from + WINDOW < text.length}"
    end

    private

    def built
      return holding_the_thread if thread

      all = [
        group("member", members),
        group("case", cases),
        group("decision", decisions),
        group("note", notes) { |note| note.body },
        group("report", reports) { |report| report.body }
      ]
      scope ? all.select { |one| one.key == scope } : all
    end

    def holding_the_thread
      [
        group("case", Case.where(id: CaseThread.where(coordinates).select(:case_id)).newest_first),
        group("decision", Decision.where(
          id: DecisionThread.where(coordinates).select(:decision_id)
        ).newest_first)
      ]
    end

    def coordinates
      { channel_id: thread.channel_id, thread_ts: thread.thread_ts }
    end

    def group(kind, found, &said)
      rows = found.limit(@limit).map do |record|
        Row.new(kind: kind, record: record,
          said: searching? && said ? self.class.snippet(said.call(record), term) : nil)
      end
      Group.new(key: kind, label: LABELS.fetch(kind), rows: rows,
        total: searching? ? found.count : rows.size)
    end

    def like
      @like ||= "%#{Member.sanitize_sql_like(term.downcase)}%"
    end

    MEMBER_ORDER = <<~SQL.squish
      (lower(coalesce(handle, '')) = :term OR lower(coalesce(display_name, '')) = :term) DESC,
      EXISTS (
        SELECT 1 FROM fd.case_participants p WHERE p.user_id = fd.member.user_id
      ) DESC,
      display_name
    SQL

    CASE_ORDER = "(id = :asked) DESC, (resolved_at IS NOT NULL), opened_at DESC".freeze

    DECISION_ORDER = <<~SQL.squish
      (lower(title) = :term) DESC,
      CASE state WHEN 'settled' THEN 0 WHEN 'proposed' THEN 1 ELSE 2 END,
      coalesce(settled_at, proposed_at) DESC
    SQL

    RECENT_CASES = 40

    def members
      return recent_members unless searching?

      Member.search(term, limit: 50)
        .reorder(Arel.sql(Member.sanitize_sql_array([MEMBER_ORDER, term: term.downcase])))
    end

    def recent_members
      ids = CaseParticipant.subjects
        .where(case_id: Case.newest_first.limit(RECENT_CASES).select(:id))
        .pluck(:user_id).uniq
      Member.where(user_id: ids).in_order_of(:user_id, ids)
    end

    def member_ids
      @member_ids ||= members.limit(10).pluck(:user_id)
    end

    def case_id
      match = /\A(?:case\s*)?#?(\d{1,9})\z/i.match(term)
      match && match[1].to_i
    end

    def cases
      return Case.reorder(Arel.sql("(resolved_at IS NOT NULL), opened_at DESC")) unless searching?

      ids = Case.where(id: reason_matches).ids
      ids += Case.with_any_subject(member_ids).ids if member_ids.any?
      ids << case_id if case_id

      Case.where(id: ids.uniq)
        .reorder(Arel.sql(Case.sanitize_sql_array([CASE_ORDER, asked: case_id || 0])))
    end

    def reason_matches
      Case.where(<<~SQL.squish, q: term)
        member_note IS NOT NULL AND to_tsvector('simple', coalesce(member_note, ''))
          @@ websearch_to_tsquery('simple', :q)
      SQL
    end

    def decisions
      ordered = Arel.sql(Decision.sanitize_sql_array([DECISION_ORDER, term: term.downcase]))
      return Decision.reorder(ordered) unless searching?

      Decision.reorder(ordered).where(<<~SQL.squish, q: term, like: like)
        to_tsvector('simple', title || ' ' || statement) @@ websearch_to_tsquery('simple', :q)
          OR lower(title) LIKE :like
          OR EXISTS (SELECT 1 FROM unnest(reasons) reason WHERE lower(reason) LIKE :like)
      SQL
    end

    def notes
      return Note.visible.recent_first unless searching?

      Note.visible.recent_first.where(<<~SQL.squish, q: term)
        to_tsvector('simple', coalesce(body, '')) @@ websearch_to_tsquery('simple', :q)
      SQL
    end

    def reports
      return CaseReport.order(received_at: :desc) unless searching?

      CaseReport.order(received_at: :desc).where(<<~SQL.squish, q: term)
        to_tsvector('simple', coalesce(body, '')) @@ websearch_to_tsquery('simple', :q)
      SQL
    end
  end
end
