module Fd
  class Search
    MIN_TERM = 2
    LIMIT = 3
    SCOPED_LIMIT = 20
    WINDOW = 90
    LEAD_IN = 30

    PREFIXES = { "@" => "member", "#" => "case",
                 "n:" => "note", "r:" => "report", "tag:" => "tag" }.freeze
    SCOPES = %w[member case note report tag].freeze

    Row = Struct.new(:kind, :record, :snippet, keyword_init: true)
    Group = Struct.new(:key, :label, :rows, :total, keyword_init: true)

    LABELS = {
      "member" => "Members",
      "case" => "Cases",
      "note" => "Notes",
      "report" => "Reports",
      "tag" => "Tags"
    }.freeze

    def initialize(term, scope: nil, limit: nil, actor: nil)
      @actor = actor
      raw = term.to_s.strip
      prefix = PREFIXES.keys.find { |key| raw.downcase.start_with?(key) }

      @scope = SCOPES.find { |kind| kind == scope.to_s } || (prefix && PREFIXES[prefix])
      @term = prefix ? raw[prefix.length..].to_s.strip : raw
      @limit = limit || (@scope ? SCOPED_LIMIT : LIMIT)
    end

    attr_reader :term, :scope

    def searching? = has_search_input? || scope.present? || thread.present?

    def has_search_input? = term.length >= MIN_TERM || case_id.present?

    def matched_member_ids = has_search_input? ? member_ids : []

    def thread
      return @thread if defined?(@thread)

      @thread = SlackLink.parse(term)
    end

    def groups
      @groups ||= searching? ? build_groups.reject { |group| group.rows.empty? } : []
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
      excerpt = text[from, WINDOW].to_s
      "#{'…' if from.positive?}#{excerpt}#{'…' if from + WINDOW < text.length}"
    end

    private

    def build_groups
      return thread_groups if thread
      return tag_groups if scope == "tag"

      all = [
        group("member", members, total: (member_matches.total if has_search_input?)),
        group("case", cases),
        group("tag", tags, total: tag_matches.count),
        group("note", notes) { |note| note.body },
        group("report", reports) { |report| report.body }
      ]
      scope ? all.select { |search_group| search_group.key == scope } : all
    end

    def tag_groups
      [group("case", tagged_cases), group("tag", tags, total: tag_matches.count)]
    end

    def thread_groups
      [
        group("case", Case.where(id: CaseThread.visible.where(coordinates).select(:case_id)).newest_first)
      ]
    end

    def coordinates
      { channel_id: thread.channel_id, thread_ts: thread.thread_ts }
    end

    def group(kind, relation, total: nil, &snippet)
      rows = relation.limit(@limit).map do |record|
        Row.new(kind: kind, record: record,
          snippet: has_search_input? && snippet ? self.class.snippet(snippet.call(record), term) : nil)
      end
      Group.new(key: kind, label: LABELS.fetch(kind), rows: rows,
        total: total || (has_search_input? ? relation.count : rows.size))
    end

    CASE_ORDER = "(id = :requested_case_id) DESC, (resolved_at IS NOT NULL), opened_at DESC".freeze

    RECENT_CASES = 40
    MEMBERS_FOR_CASES = 10

    def members
      return recent_members unless has_search_input?

      ids = member_matches.ids
      return Member.none if ids.empty?

      Member.where(user_id: ids).in_order_of(:user_id, ids)
    end

    def member_matches
      @member_matches ||= MemberFinder.new(term, actor: @actor)
        .find(limit: [@limit, MEMBERS_FOR_CASES].max)
    end

    def recent_members
      ids = CaseParticipant.subjects
        .where(case_id: Case.newest_first.limit(RECENT_CASES).select(:id))
        .pluck(:user_id).uniq
      Member.where(user_id: ids).in_order_of(:user_id, ids)
    end

    def member_ids
      @member_ids ||= members.limit(MEMBERS_FOR_CASES).pluck(:user_id)
    end

    def case_id
      match = /\A(?:case\s*)?#?(\d{1,9})\z/i.match(term)
      match && match[1].to_i
    end

    def cases
      return Case.reorder(Arel.sql("(resolved_at IS NOT NULL), opened_at DESC")) unless has_search_input?

      ids = Case.where(id: reason_matches).ids
      ids += Case.with_any_subject(member_ids).ids if member_ids.any?
      ids << case_id if case_id

      Case.where(id: ids.uniq)
        .reorder(Arel.sql(Case.sanitize_sql_array([CASE_ORDER, requested_case_id: case_id || 0])))
    end

    def reason_matches
      Case.where(<<~SQL.squish, q: term)
        member_note IS NOT NULL AND to_tsvector('simple', coalesce(member_note, ''))
          @@ websearch_to_tsquery('simple', :q)
      SQL
    end

    def tag_name = Tag.normalise(term)

    def tag_matches
      return Tag.none unless has_search_input? || scope == "tag"
      return Tag.all if tag_name.blank?

      Tag.where("fd.tags.name LIKE ?", "%#{Tag.sanitize_sql_like(tag_name)}%")
    end

    def tags
      Tag.with_uses.where(id: tag_matches.select(:id))
        .reorder(Arel.sql("COUNT(fd.case_tags.tag_id) DESC, fd.tags.name"))
    end

    def tagged_cases
      tag = Tag.find_by(name: tag_name) if tag_name.present?
      return Case.none if tag.nil?

      Case.where(id: CaseTag.where(tag_id: tag.id).select(:case_id))
        .reorder(Arel.sql("(resolved_at IS NOT NULL), opened_at DESC"))
    end

    def notes
      return Note.visible.recent_first unless has_search_input?

      Note.visible.recent_first.where(<<~SQL.squish, q: term)
        to_tsvector('simple', coalesce(body, '')) @@ websearch_to_tsquery('simple', :q)
      SQL
    end

    def reports
      return CaseReport.order(received_at: :desc) unless has_search_input?

      CaseReport.order(received_at: :desc).where(<<~SQL.squish, q: term)
        to_tsvector('simple', coalesce(body, '')) @@ websearch_to_tsquery('simple', :q)
      SQL
    end
  end
end
