module Fd
  class Deeds
    LIMIT = 40
    READ = "identity.read".freeze

    Row = Struct.new(:at, :event, :kind, :id, :about, :who, :said, :actor, keyword_init: true)

    ON_CASE = %w[case participant assignee thread citation].freeze

    def initialize(user_id, since:, only: nil, limit: LIMIT)
      @user_id = user_id
      @since = since
      @only = only
      @limit = limit
    end

    def rows
      @rows ||= @only == READ ? reads : built
    end

    def member_ids
      rows.flat_map { |row| [row.kind == "member" ? row.id : row.who, row.actor] }.compact.uniq
    end

    private

    def reads
      scope = AccessLog.where(field_class: "identity").where(looked_at: @since..)
      scope = scope.where(actor_id: @user_id) if @user_id
      scope.order(looked_at: :desc).limit(@limit).map do |log|
        Row.new(at: log.looked_at, event: "identity/read", kind: "member",
          id: log.subject_user_id, actor: log.actor_id)
      end
    end

    def entries
      scope = AuditEntry.where(occurred_at: @since..).where.not(verb: "refused")
      scope = scope.where(actor_user_id: @user_id) if @user_id
      scope = narrow(scope, Permission.events(@only)) if @only
      scope.recent_first.limit(@limit).to_a
    end

    def narrow(scope, events)
      pairs = events.map { |event| event.split("/") }
      return scope.none if pairs.empty?

      scope.where(pairs.map { "(entity_type = ? AND verb = ?)" }.join(" OR "), *pairs.flatten)
    end

    def built
      found = entries
      @actions = Action.where(id: ids(found, "action")).index_by(&:id)
      @notes = Note.where(id: ids(found, "note")).index_by(&:id)
      @reports = CaseReport.where(id: ids(found, "report")).index_by(&:id)
      @grants = AccessGrant.where(id: ids(found, "grant")).index_by(&:id)
      @titles = Decision.where(id: ids(found, "decision", "decision_thread"))
        .pluck(:id, :title).to_h

      found.map { |row| row_for(row).tap { |made| made.actor = row.actor_user_id } }
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
      when "grant" then grant_row(row, event)
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
      grant = @grants[row.entity_id]
      return Row.new(at: row.occurred_at, event: event) if grant.nil?

      Row.new(at: row.occurred_at, event: event, kind: "member", id: grant.user_id,
        said: grant.role.tr("_", " "))
    end
  end
end
