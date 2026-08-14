module Fd
  class Search
    MIN_TERM = 2
    LIMIT = 3
    WINDOW = 90
    LEAD_IN = 30

    Row = Struct.new(:kind, :record, :said, keyword_init: true)
    Group = Struct.new(:key, :label, :rows, :total, keyword_init: true)

    LABELS = {
      "member" => "Members",
      "case" => "Cases",
      "decision" => "Decisions",
      "note" => "Notes",
      "report" => "Reports"
    }.freeze

    def initialize(term, limit: LIMIT)
      @term = term.to_s.strip
      @limit = limit
    end

    attr_reader :term

    def asked? = term.length >= MIN_TERM

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
      [
        group("member", members),
        group("case", cases),
        group("decision", decisions),
        group("note", notes) { |note| note.body },
        group("report", reports) { |report| report.body }
      ]
    end

    def group(kind, scope, &said)
      rows = scope.limit(@limit).map do |record|
        Row.new(kind: kind, record: record, said: said && self.class.snippet(said.call(record), term))
      end
      Group.new(key: kind, label: LABELS.fetch(kind), rows: rows, total: scope.count)
    end

    def like
      @like ||= "%#{Member.sanitize_sql_like(term.downcase)}%"
    end

    def members
      Member.search(term, limit: 50)
    end

    def member_ids
      @member_ids ||= members.limit(10).pluck(:user_id)
    end

    def case_id
      match = /\A(?:case\s*)?#?(\d{1,9})\z/i.match(term)
      match && match[1].to_i
    end

    def cases
      ids = Case.where(id: reason_matches).ids
      ids += Case.with_any_subject(member_ids).ids if member_ids.any?
      ids << case_id if case_id

      Case.where(id: ids.uniq).newest_first
    end

    def reason_matches
      Case.where(<<~SQL.squish, q: term)
        member_note IS NOT NULL AND to_tsvector('simple', coalesce(member_note, ''))
          @@ websearch_to_tsquery('simple', :q)
      SQL
    end

    def decisions
      Decision.where(<<~SQL.squish, q: term, like: like).newest_first
        to_tsvector('simple', title || ' ' || statement) @@ websearch_to_tsquery('simple', :q)
          OR lower(title) LIKE :like
          OR EXISTS (SELECT 1 FROM unnest(reasons) reason WHERE lower(reason) LIKE :like)
      SQL
    end

    def notes
      Note.visible.recent_first.where(<<~SQL.squish, q: term)
        to_tsvector('simple', coalesce(body, '')) @@ websearch_to_tsquery('simple', :q)
      SQL
    end

    def reports
      CaseReport.order(received_at: :desc).where(<<~SQL.squish, q: term)
        to_tsvector('simple', coalesce(body, '')) @@ websearch_to_tsquery('simple', :q)
      SQL
    end
  end
end
