module Fd
  class CasesController < BaseController
    def index
      @open_modal = params[:open] == "1"
      load_queue
    end

    def show
      @case = Case.find(params[:id])
      @threads = @case.threads.primary_first.to_a
      @participants = @case.participants.by_role.to_a
      @others = @participants.reject { |person| person.role == "subject" }
      @people = CasePeople.for(@participants, asked: params[:person])
      @reports = @case.reports.oldest_first.to_a
      @actions = @case.actions.oldest_first.to_a
      @live_actions = @actions.reject(&:reversed?)
      @siblings = @case.sibling_cases.includes(:subjects).oldest_first.to_a
      @duplicate_candidates = Case.candidates_for(@case, @siblings)
      @notes = @case.notes.visible.recent_first.to_a
      @standing_notes = Note.for_subjects(@participants.map(&:user_id)).visible.recent_first
        .group_by(&:subject_user_id)
      @thread_messages = ThreadMessage.for_threads(@threads).to_a
      @case_person = CasePerson.for(@people.chosen, kase: @case, actions: @actions,
        notes: @notes, messages: @thread_messages)
      @thread_list = CaseThreads.for(@threads, actions: @actions,
        messages: @thread_messages, asked: params[:thread])
      @flags = @case.citations.index_by(&:thread_message_id)
      @flagged_messages = @thread_messages.select { |said| @flags.key?(said.id) }
      @cited_by = @actions.select(&:cites?).group_by(&:cites_message_id)
      @assignees = @case.assignees.to_a
      @mentioned = @case.mentioned_but_unlogged(
        notes: @notes + @standing_notes.values.flatten, reports: @reports
      )
      @names = Names.for(page_ids)
      @timeline = CaseTimeline.for(
        @case,
        reports: @reports,
        actions: @actions,
        notes: @notes + @standing_notes.values_at(*@case.subject_user_ids).compact.flatten,
        participants: @participants,
        assignees: @assignees,
        names: @names,
      )
      @context = MemberContext.for(
        @case.subject_user_ids +
          @participants.map(&:user_id) +
          @siblings.flat_map(&:subject_user_ids)
      )
    end

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    def create
      subjects = asked_subjects
      @open_for_subject = open_cases_for(subjects)

      problem = objection(subjects)
      return refuse(problem) if problem
      return refuse(already_open_warning) if warn_about_open_case?

      kase = nil
      writing do
        kase = Case.create!(
          category_key: params[:category_key].presence,
          opened_by: current_staff.user_id,
          opened_at: Time.current,
          source_app: Audit::SOURCE_APP
        )
        audit(kase, "opened")
        subjects.each { |id| audit(kase.add_subject!(id), "attached", entity_id: kase.id) }
        if params[:assign_to_me] == "1"
          audit(kase.assign!(current_staff.user_id), "claimed", entity_id: kase.id)
        end
        write_first_note(kase)
      end

      redirect_to fd_case_path(kase), notice: opened_notice(kase, subjects)
    end

    private

    def page_ids
      [
        @case.opened_by,
        @participants.map(&:user_id),
        @assignees.flat_map { |person| [person.user_id, person.assigned_by] },
        @reports.map(&:reporter_user_id),
        @actions.flat_map { |a| [a.target_user_id, a.decided_by, a.performed_by, a.reversed_by] },
        (@notes + @standing_notes.values.flatten).map(&:author),
        @siblings.flat_map(&:subject_user_ids),
        (@notes + @standing_notes.values.flatten).flat_map { |note| Mentions.ids(note.body) },
        @reports.flat_map { |report| Mentions.ids(report.body) },
        @thread_messages.map(&:author_user_id),
        @threads.map(&:added_by)
      ]
    end

    def asked_subjects
      raw = params[:subject_user_ids].presence || [params[:subject_user_id]]
      Array(raw).map { |id| id.to_s.strip.delete_prefix("@").upcase }.reject(&:blank?).uniq
    end

    def preset_for(subjects)
      return [] if subjects.empty?

      known = Names.for(subjects)
      subjects.map do |id|
        { id: id, name: known[id], initial: known.member(id)&.initial || id[0] }
      end
    end

    def open_cases_for(subjects)
      return [] if subjects.empty?

      Case.unresolved.with_any_subject(subjects).includes(:subjects).oldest_first.to_a
    end

    def objection(subjects)
      return "say who this case is about" if subjects.empty?
      unless subjects.all? { |id| id.match?(MEMBER_ID) }
        return "that does not look like a Slack member id"
      end
      if params[:category_key].present? && !Case::CATEGORIES.include?(params[:category_key])
        return "pick a category from the list"
      end

      nil
    end

    def warn_about_open_case?
      @open_for_subject.any? && params[:separate] != "1"
    end

    def already_open_warning
      caught = (@open_for_subject.flat_map(&:subject_user_ids) & asked_subjects).uniq
      who = Names.for(caught).list(caught)
      numbers = @open_for_subject.map { |kase| "##{kase.id}" }.to_sentence
      "#{who} already #{caught.many? ? 'have' : 'has'} an open case, #{numbers}. " \
        "Add to that one, or open a new case."
    end

    def opened_notice(kase, subjects)
      return "case #{kase.id} opened" if subjects.one?

      "case #{kase.id} opened, about #{subjects.size} people"
    end

    def write_first_note(kase)
      body = Mentions.normalise(params[:body].to_s.strip)
      return if body.blank?

      note = Note.create!(case_id: kase.id, body: body, author: current_staff.user_id)
      audit(note, "noted")
    end

    def refuse(message)
      flash.now[:alert] = message
      @open_modal = true
      load_queue
      render :index, status: :unprocessable_content
    end

    def load_queue
      @query = CaseQuery.new(params, viewer: current_staff&.user_id)
      @cases = @query.relation.includes(:subjects, :assignees).to_a
      @context = MemberContext.for(@cases.flat_map(&:subject_user_ids))
      @action_counts = Action.where(case_id: @cases.map(&:id)).group(:case_id).count
      @stats = QueueStats.load
      @total_count = @stats.total
      @views = @query.views
      @subject_preset = preset_for(asked_subjects)
      @names = Names.for(@cases.flat_map { |kase|
        kase.subject_user_ids + kase.assignee_user_ids
      })
      @open_for_subject ||= []
    end
  end
end
