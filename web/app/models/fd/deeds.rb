module Fd
  class Deeds
    LIMIT = 40
    READ = "identity.read".freeze

    Row = Struct.new(:at, :event, :kind, :id, :about, :who, :said, :actor, keyword_init: true)

    ON_CASE = %w[case participant assignee thread citation].freeze

    def initialize(user_id, since:, only: nil, limit: LIMIT, offset: 0)
      @user_id = user_id
      @since = since
      @only = only
      @limit = limit
      @offset = offset
    end

    def rows
      @rows ||= built
    end

    def total
      @total ||= picked("count(*) AS found").first["found"].to_i
    end

    def member_ids
      rows.flat_map { |row| [row.kind == "member" ? row.id : row.who, row.actor] }.compact.uniq
    end

    private

    def picked(select = "kind, id, at")
      return AuditEntry.connection.select_all("SELECT 0 AS found WHERE false") if nothing_asked?

      sql = <<~SQL
        WITH picked AS (#{audit_side}#{reads_side})
        SELECT #{select} FROM picked
      SQL
      sql += "ORDER BY at DESC LIMIT :limit OFFSET :offset" unless select.start_with?("count")
      AuditEntry.connection.select_all(
        AuditEntry.sanitize_sql([sql, { since: @since, who: @user_id,
                                        limit: @limit, offset: @offset }])
      )
    end

    def nothing_asked?
      audit_side.strip.empty? && reads_side.strip.empty?
    end

    def audit_side
      return "" if @only && @only != READ && Authz.events(@only).empty?
      return "" if @only == READ

      mine = @user_id ? "AND a.actor_user_id = :who" : ""
      <<~SQL
        SELECT 'audit' AS kind, a.id AS id, a.occurred_at AS at
        FROM fd.audit a
        WHERE a.occurred_at >= :since AND a.verb <> 'refused' #{mine} #{only_clause}
      SQL
    end

    IDENTITY_READS = %w[identity identity_search].freeze

    def reads_side
      return "" if @only && @only != READ

      mine = @user_id ? "AND l.actor_id = :who" : ""
      lead = audit_side.empty? ? "" : "UNION ALL"
      classes = AuditEntry.sanitize_sql(["l.field_class IN (?)", IDENTITY_READS])
      <<~SQL
        #{lead}
        SELECT 'read' AS kind, l.id AS id, l.looked_at AS at
        FROM access_log l
        WHERE l.looked_at >= :since AND #{classes} #{mine}
      SQL
    end

    def only_clause
      return "" unless @only

      pairs = Authz.events(@only).map { |event| event.split("/") }
      return "AND false" if pairs.empty?

      said = pairs.map { |type, verb|
        AuditEntry.sanitize_sql(["(a.entity_type = ? AND a.verb = ?)", type, verb])
      }
      "AND (#{said.join(' OR ')})"
    end

    def entries
      AuditEntry.where(id: @picked_ids).recent_first.to_a
    end

    def narrow(scope, events)
      pairs = events.map { |event| event.split("/") }
      return scope.none if pairs.empty?

      scope.where(pairs.map { "(entity_type = ? AND verb = ?)" }.join(" OR "), *pairs.flatten)
    end

    def built
      chosen = picked.to_a
      @picked_ids = chosen.select { |row| row["kind"] == "audit" }.map { |row| row["id"] }
      read_rows = reads_for(chosen.select { |row| row["kind"] == "read" }.map { |row| row["id"] })

      found = entries
      @actions = Action.where(id: ids(found, "action")).index_by(&:id)
      @notes = Note.where(id: ids(found, "note")).index_by(&:id)
      @reports = CaseReport.where(id: ids(found, "report")).index_by(&:id)
      @titles = Decision.where(id: ids(found, "decision", "decision_thread"))
        .pluck(:id, :title).to_h

      made = found.map { |row| row_for(row).tap { |one| one.actor = row.actor_user_id } }
      (made + read_rows).sort_by { |row| -row.at.to_i }
    end

    def reads_for(ids)
      return [] if ids.empty?

      AccessLog.where(id: ids).map do |log|
        searched = log.field_class == "identity_search"
        Row.new(at: log.looked_at, event: "identity/read", kind: "member",
          id: log.subject_user_id, actor: log.actor_id,
          said: ("found by searching" if searched))
      end
    end

    def ids(found, *types)
      found.select { |row| types.include?(row.entity_type) }.map(&:entity_id)
    end

    def row_for(row)
      event = "#{row.entity_type}/#{row.verb}"

      case row.entity_type
      when "action" then action_row(row, event)
      when "note" then note_row(row, event)
      when "decision", "decision_thread" then decision_row(row, event)
      when "grant", "capability_grant" then grant_row(row, event)
      when "community_grant" then community_grant_row(row, event)
      when "permission" then moved_row(row, event)
      when "report" then report_row(row, event)
      when *ON_CASE then on_case(row, event, row.entity_id)
      else Row.new(at: row.occurred_at, event: event)
      end
    end

    def on_case(row, event, case_id, who: nil, said: nil)
      return Row.new(at: row.occurred_at, event: event, who: who, said: said) if case_id.nil?

      Row.new(at: row.occurred_at, event: event, kind: "case", id: case_id,
        about: "case #{case_id}", who: who, said: said)
    end

    def action_row(row, event)
      action = @actions[row.entity_id]
      return on_case(row, event, nil) if action.nil?

      on_case(row, event, action.case_id, who: action.target_user_id,
        said: action.type_key.tr("_", " "))
    end

    def note_row(row, event)
      note = @notes[row.entity_id]
      return on_case(row, event, nil) if note.nil?
      return on_case(row, event, note.case_id) if note.case_id

      Row.new(at: row.occurred_at, event: event, kind: "member", id: note.subject_user_id)
    end

    def report_row(row, event)
      report = @reports[row.entity_id]
      on_case(row, event, report ? report.case_id : row.entity_id)
    end

    def decision_row(row, event)
      title = @titles[row.entity_id]
      return Row.new(at: row.occurred_at, event: event) if title.nil?

      Row.new(at: row.occurred_at, event: event, kind: "decision", id: row.entity_id,
        about: title)
    end

    def moved_row(row, event)
      said = row.after || {}
      Row.new(at: row.occurred_at, event: event,
        said: [said["permission"], said["role"]&.tr("_", " ")].compact.join(" · ").presence)
    end

    def grant_row(row, event)
      said = row.after.presence || row.before.presence || {}
      return Row.new(at: row.occurred_at, event: event) if said["user_id"].blank?

      Row.new(at: row.occurred_at, event: event, kind: "member", id: said["user_id"],
        said: said["role"]&.tr("_", " "))
    end

    def community_grant_row(row, event)
      said = row.after.presence || row.before.presence || {}
      return Row.new(at: row.occurred_at, event: event) if said["user_id"].blank?

      Row.new(at: row.occurred_at, event: event, kind: "member", id: said["user_id"],
        said: [said["role"]&.tr("_", " "), said["family"]].compact.join(", ").presence)
    end
  end
end
