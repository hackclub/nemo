module Fd
  class SearchesController < BaseController
    ICONS = { "member" => "👤", "case" => "📁", "decision" => "📓",
              "note" => "📝", "report" => "📨" }.freeze

    def show
      found = Search.new(params[:q], scope: params[:scope])
      render json: { term: found.term, scope: found.scope,
                     groups: found.asked? ? shown(found) : resting }
    end

    private

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
        { key: "do", label: "Do", total: 2, rows: [
          { kind: "do", icon: "⚡", title: "Open a case", sub: nil, url: fd_cases_path },
          { kind: "do", icon: "📓", title: "Write a decision", sub: nil, url: fd_decisions_path }
        ] }
      ].reject { |group| group[:rows].empty? }
    end

    def waiting
      rows = []
      unassigned = Case.unresolved.unassigned.count
      if unassigned.positive?
        rows << { kind: "case", icon: "⏳", title: helpers.pluralize(unassigned, "unassigned case"),
                  sub: oldest_unassigned, url: fd_cases_path(view: "unassigned") }
      end

      proposals = Decision.unsettled.count
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
