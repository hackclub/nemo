module Fd
  class CasesController < BaseController
    FILTERS = %w[open mine all].freeze
    DEFAULT_FILTER = "open".freeze

    def index
      load_queue
    end

    def show
      @case = Case.find(params[:id])
      @threads = @case.threads.primary_first.to_a
      @participants = @case.participants.by_role.to_a
      @others = @participants.reject { |person| person.role == "subject" }
      @reports = @case.reports.oldest_first.to_a
      @actions = @case.actions.oldest_first.to_a
      @live_actions = @actions.reject(&:reversed?)
      @siblings = @case.sibling_cases.includes(:subjects).oldest_first.to_a
      @duplicate_candidates = Case.candidates_for(@case, @siblings)
      @notes = @case.notes.visible.recent_first.to_a
      @standing_notes = Note.for_subjects(@case.subject_user_ids).visible.recent_first
        .group_by(&:subject_user_id)
      @timeline = CaseTimeline.for(
        @case,
        reports: @reports,
        actions: @actions,
        notes: @notes + @standing_notes.values.flatten,
        participants: @participants,
      )
      @context = MemberContext.for(
        @case.subject_user_ids +
          @participants.map(&:user_id) +
          @siblings.flat_map(&:subject_user_ids)
      )
    end

    def create
      subject = params[:subject_user_id].to_s.strip.presence
      @open_for_subject = subject ? Case.unresolved.with_subject(subject).to_a : []

      problem = objection(subject)
      return refuse(problem) if problem
      return refuse(already_open_warning) if warn_about_open_case?

      kase = nil
      writing do
        kase = Case.create!(
          category_key: params[:category_key].presence,
          opened_by: current_staff.user_id,
          opened_at: Time.current,
          claimed_by: (current_staff.user_id if params[:assign_to_me] == "1"),
          claimed_at: (Time.current if params[:assign_to_me] == "1"),
          source_app: Audit::SOURCE_APP
        )
        audit(kase, "opened")
        audit(kase.add_subject!(subject), "attached", entity_id: kase.id)
        write_first_note(kase)
      end

      redirect_to fd_case_path(kase), notice: "case #{kase.id} opened"
    end

    private

    def objection(subject)
      return "say who this case is about" if subject.nil?
      if params[:category_key].present? && !Case::CATEGORIES.include?(params[:category_key])
        return "pick a category from the list"
      end

      nil
    end

    def warn_about_open_case?
      @open_for_subject.any? && params[:separate] != "1"
    end

    def already_open_warning
      numbers = @open_for_subject.map { |kase| "##{kase.id}" }.to_sentence
      "@#{params[:subject_user_id]} already has an open case, #{numbers}. " \
        "Add to that one, or open a new case."
    end

    def write_first_note(kase)
      body = params[:body].to_s.strip
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
      @filter = FILTERS.include?(params[:filter]) ? params[:filter] : DEFAULT_FILTER
      @cases = scope_for(@filter).includes(:subjects).to_a
      @context = MemberContext.for(@cases.flat_map(&:subject_user_ids))
      @action_counts = Action.where(case_id: @cases.map(&:id)).group(:case_id).count
      @open_count = Case.unresolved.count
      @unassigned_count = Case.unresolved.where(claimed_by: nil).count
      @open_for_subject ||= []
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
