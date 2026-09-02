module Fd
  class SearchesController < BaseController
    permit "case.read"
    ICONS = { "member" => "👤", "case" => "📁", "decision" => "📓",
              "note" => "📝", "report" => "📨" }.freeze

    PAGE_LIMIT = 20

    def show
      respond_to do |format|
        format.json { render json: payload }
        format.html { page }
      end
    end

    private

    def payload
      return commanding if commanding?

      found = Search.new(params[:q], scope: params[:scope])
      { term: found.term, scope: found.scope,
        groups: found.asked? ? shown(found) : resting }
    end

    def page
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @found = Search.new(params[:q], scope: params[:scope], limit: PAGE_LIMIT)
      @groups = @found.asked? ? shown(@found) : []
      @took = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      @counts = every_count
    end

    def every_count
      whole = Search.new(params[:q], limit: 1)
      return {} unless whole.asked?

      whole.groups.to_h { |group| [group.key, group.total] }
    end

    def commanding?
      params[:q].to_s.start_with?(">") || params[:scope] == "command"
    end

    def commanding
      term = params[:q].to_s.delete_prefix(">").strip
      rows = commands.select { |row| term.blank? || row[:title].downcase.include?(term.downcase) }

      { term: term, scope: "command",
        groups: [{ key: "command", label: "Commands", total: rows.size, rows: gated(rows) }] }
    end

    def gated(rows)
      rows.map do |row|
        key = row.delete(:key)
        on = row.delete(:on)
        row.merge(why: key && Access.why_not(current_account, key, on))
      end
    end

    def decisions?
      Flag.on?(:decisions)
    end

    def commands
      here + [
        { kind: "do", icon: "⚡", title: "Open a case", sub: nil, key: "case.open",
          url: fd_cases_path(open: "1") },
        ({ kind: "do", icon: "📓", title: "Write a decision", sub: nil, key: "decision.write",
           url: fd_decisions_path(new: "1") } if decisions?),
        { kind: "do", icon: "📁", title: "Go to the cases", sub: nil, url: fd_cases_path },
        { kind: "do", icon: "👤", title: "Go to the members", sub: nil, url: fd_members_path },
        ({ kind: "do", icon: "📓", title: "Go to the decisions", sub: nil,
           url: fd_decisions_path } if decisions?)
      ].compact
    end

    def here
      kase = Case.find_by(id: params[:on_case])
      return decision_commands if kase.nil?

      on = "on case #{kase.id}"
      [
        { kind: "do", icon: "⚡", title: "Resolve this case", sub: on,
          key: "case.resolve", on: kase, url: fd_case_path(kase, do: "resolve") },
        { kind: "do", icon: "⚡", title: "Log an action", sub: on,
          key: "case.act", on: kase, url: fd_case_path(kase, do: "action") },
        { kind: "do", icon: "📝", title: "Add a note", sub: on,
          key: "case.note", url: fd_case_path(kase, do: "note") },
        { kind: "do", icon: "🔗", title: "Attach a thread", sub: on,
          key: "case.thread", on: kase, url: fd_case_path(kase, do: "thread") },
        ({ kind: "do", icon: "📓", title: "Link a decision", sub: on,
           key: "decision.link", url: fd_case_path(kase, do: "decision") } if decisions?)
      ].compact
    end

    def decision_commands
      return [] unless decisions?

      decision = Decision.find_by(id: params[:on_decision])
      return [] if decision.nil?

      on = "on #{decision.title}"
      [
        { kind: "do", icon: "📝", title: "Edit the wording", sub: on, key: "decision.write",
          url: fd_decision_path(decision, do: "edit") },
        { kind: "do", icon: "🔗", title: "Link threads", sub: on, key: "decision.link",
          url: fd_decision_path(decision, do: "threads") }
      ]
    end

    def shown(found)
      @names = Names.for(found.groups.flat_map { |group| named_in(group) })
      @context = MemberContext.for(member_ids(found))

      found.groups.map do |group|
        { key: group.key, label: group.label, total: group.total,
          rows: group.rows.map { |row| row_for(row) } }
      end
    end

    def resting
      [
        { key: "waiting", label: "Waiting on you", total: 2, rows: waiting },
        { key: "do", label: "Do", total: 2, rows: gated([
          { kind: "do", icon: "⚡", title: "Open a case", sub: nil, key: "case.open",
            url: fd_cases_path },
          ({ kind: "do", icon: "📓", title: "Write a decision", sub: nil,
             key: "decision.write", url: fd_decisions_path } if decisions?)
        ].compact) }
      ].reject { |group| group[:rows].empty? }
    end

    def waiting
      rows = []
      unassigned = Case.unresolved.unassigned.count
      if unassigned.positive?
        rows << { kind: "case", icon: "⏳", title: helpers.pluralize(unassigned, "unassigned case"),
                  sub: oldest_unassigned, url: fd_cases_path(view: "unassigned") }
      end

      proposals = decisions? ? Decision.unsettled.count : 0
      if proposals.positive?
        rows << { kind: "decision", icon: "⏳",
                  title: "#{helpers.pluralize(proposals, 'proposal')} to settle",
                  sub: nil, url: fd_decisions_path(view: "proposed") }
      end
      rows
    end

    def oldest_unassigned
      oldest = Case.unresolved.unassigned.minimum(:opened_at)
      oldest && "oldest #{helpers.case_age_label(Time.current - oldest)}"
    end

    def named_in(group)
      group.rows.flat_map do |row|
        case row.record
        when Member then [row.record.user_id]
        when Case then row.record.subject_user_ids + row.record.assignee_user_ids
        when Note then [row.record.author]
        when CaseReport then [row.record.reporter_user_id]
        else []
        end
      end.compact
    end

    def member_ids(found)
      found.groups.flat_map { |group| group.rows.map(&:record) }
        .grep(Member).map(&:user_id)
    end

    def row_for(row)
      record = row.record
      {
        kind: row.kind,
        icon: ICONS.fetch(row.kind, "•"),
        title: title_for(record),
        sub: sub_for(record),
        said: row.said,
        url: url_for_record(record)
      }
    end

    def title_for(record)
      case record
      when Member then "@#{record.handle.presence || record.display_name}"
      when Case then "case #{record.id}"
      when Decision then record.title
      when Note then record.case_id ? "case #{record.case_id}" : @names[record.subject_user_id]
      when CaseReport then "case #{record.case_id}"
      end
    end

    def sub_for(record)
      case record
      when Member then member_sub(record)
      when Case then case_sub(record)
      when Decision then decision_sub(record)
      when Note then "#{@names[record.author]} · #{record.created_at.strftime('%-d %b')}"
      when CaseReport then report_sub(record)
      end
    end

    def member_sub(member)
      seen = @context[member.user_id]
      parts = [helpers.tenure_label(seen&.tenure_days)]
      parts << "#{helpers.number_with_delimiter(seen.messages_posted)} messages" if
        seen&.messages_posted
      priors = Case.prior_count(member.user_id, within: Case::PRIOR_WINDOW)
      parts << helpers.pluralize(priors, "prior") if priors.positive?
      open = Case.unresolved.with_subject(member.user_id).count
      parts << "#{open} open" if open.positive?
      parts.compact.join(" · ")
    end

    def case_sub(kase)
      parts = [helpers.category_label(kase.category_key).downcase]
      parts << if kase.resolved?
        helpers.resolution_label(kase.resolution).downcase
      else
        "open #{helpers.case_age_label(helpers.case_age_seconds(kase))}"
      end
      parts << @names.list(kase.assignee_user_ids) if kase.assigned?
      parts.join(" · ")
    end

    STATES = { "settled" => "in force", "proposed" => "proposed",
               "superseded" => "retired" }.freeze

    def decision_sub(decision)
      followed = decision.cases_followed.count
      [STATES.fetch(decision.state), followed.positive? ? "#{followed} cases" : nil]
        .compact.join(" · ")
    end

    def report_sub(report)
      who = report.anonymous? ? "anonymous" : @names[report.reporter_user_id]
      "#{who} · #{report.received_at.strftime('%-d %b')}"
    end

    def url_for_record(record)
      case record
      when Member then fd_member_path(record.user_id)
      when Case then fd_case_path(record)
      when Decision then fd_decision_path(record)
      when Note then record.case_id ? fd_case_path(record.case_id) : fd_member_path(record.subject_user_id)
      when CaseReport then fd_case_path(record.case_id)
      end
    end
  end
end
