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
      @siblings = @case.sibling_cases.oldest_first.to_a
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

    private

    def scope_for(filter)
      case filter
      when "mine" then Case.unresolved.where(claimed_by: current_staff.user_id).oldest_first
      when "all" then Case.newest_first
      else Case.unresolved.oldest_first
      end
    end
  end
end
