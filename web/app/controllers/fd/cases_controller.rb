module Fd
  class CasesController < BaseController
    FILTERS = %w[open mine all].freeze
    DEFAULT_FILTER = "open".freeze

    def index
      @filter = FILTERS.include?(params[:filter]) ? params[:filter] : DEFAULT_FILTER
      @cases = scope_for(@filter).to_a
      @context = MemberContext.for(@cases.map(&:subject_user_id))
      @action_counts = Action.where(case_id: @cases.map(&:id)).group(:case_id).count
      @open_count = Case.unresolved.count
      @unassigned_count = Case.unresolved.where(claimed_by: nil).count
    end

    def show
      @case = Case.find(params[:id])
      @threads = @case.threads.primary_first.to_a
      @participants = @case.participants.by_role.to_a
      @reports = @case.reports.oldest_first.to_a
      @actions = @case.actions.oldest_first.to_a
      @live_actions = @actions.reject(&:reversed?)
      @siblings = @case.sibling_cases.oldest_first.to_a
      @duplicate_candidates = Case.candidates_for(@case, @siblings)
      @notes = @case.notes.visible.recent_first.to_a
      @standing_notes = Note.for_subject(@case.subject_user_id).visible.recent_first.to_a
      @timeline = CaseTimeline.for(
        @case,
        reports: @reports,
        actions: @actions,
        notes: @notes + @standing_notes,
        participants: @participants,
      )
      @context = MemberContext.for(
        [@case.subject_user_id] +
          @participants.map(&:user_id) +
          @siblings.map(&:subject_user_id)
      )
    end

    def new
      @open_for_subject = []
    end

    def create
      subject = params[:subject_user_id].to_s.strip.presence
      @open_for_subject = subject ? Case.unresolved.where(subject_user_id: subject).to_a : []

      problem = objection(subject)
      return refuse(problem) if problem

      kase = nil
      writing do
        kase = Case.create!(
          subject_user_id: subject,
          category_key: params[:category_key].presence,
          learned_from: params[:learned_from],
          opened_by: current_staff.user_id,
          opened_at: Time.current,
          claimed_by: (current_staff.user_id if params[:assign_to_me] == "1"),
          claimed_at: (Time.current if params[:assign_to_me] == "1"),
          source_app: Audit::SOURCE_APP
        )
        audit(kase, "opened")
        attach_first_thread(kase)
        write_first_note(kase)
      end

      redirect_to fd_case_path(kase), notice: "case #{kase.id} opened"
    end

    private

    def objection(subject)
      return "say who this case is about" if subject.nil?
      unless Case::LEARNED_FROM.include?(params[:learned_from])
        return "say how you learned about it"
      end
      if params[:category_key].present? && !Case::CATEGORIES.include?(params[:category_key])
        return "pick a category from the list"
      end
      if params[:link].present? && SlackLink.parse(params[:link]).nil?
        return "that is not a link to a Slack thread in this workspace"
      end

      nil
    end

    def attach_first_thread(kase)
      ref = SlackLink.parse(params[:link])
      return if ref.nil?

      kind = CaseThread::KINDS.include?(params[:kind]) ? params[:kind] : "evidence"
      thread = CaseThread.create!(
        case_id: kase.id, channel_id: ref.channel_id, thread_ts: ref.thread_ts,
        kind: kind, is_primary: kind == "evidence", added_by: current_staff.user_id
      )
      audit(thread, "attached")
    end

    def write_first_note(kase)
      body = params[:body].to_s.strip
      return if body.blank?

      note = Note.create!(case_id: kase.id, body: body, author: current_staff.user_id)
      audit(note, "noted")
    end

    def refuse(message)
      flash.now[:alert] = message
      render :new, status: :unprocessable_content
    end

    def scope_for(filter)
      case filter
      when "mine" then Case.unresolved.where(claimed_by: current_staff.user_id).oldest_first
      when "all" then Case.newest_first
      else Case.unresolved.oldest_first
      end
    end
  end
end
