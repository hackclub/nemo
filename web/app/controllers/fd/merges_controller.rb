module Fd
  class MergesController < BaseController
    permit "case.resolve"

    PER_PAGE = 8

    def show
      @case = Case.find(params[:id])
      @term = params[:q].to_s.strip
      @page = [params[:page].to_i, 1].max
      @siblings = @case.sibling_cases.includes(:subjects).oldest_first.to_a
      @groups, @more = @term.present? ? [found_groups, false] : candidate_page
      @candidates = @groups.flat_map(&:last)
      read_reports(@candidates)
      @names = Names.for((@candidates + [@case])
        .flat_map(&:subject_user_ids) + [@case.opened_by] +
        @candidates.flat_map(&:assignee_user_ids) +
        @candidates.map(&:opened_by) +
        @candidates.flat_map { |kase| kase.reports.map(&:reporter_user_id) } +
        @cited_words.values.map(&:author))
      render "more", layout: false if @page > 1
    end

    def confirm
      ids = ticked_ids
      return refuse("tick at least two cases to merge") if ids.size < 2

      @carry = query_params
      cases = Case.where(id: ids).includes(:subjects, :assignees, :reports, :participants)
        .oldest_first.to_a
      return refuse("those cases are gone") if cases.size < 2

      @plan = MergePlan.over(cases, keeper: params[:keep])
      @names = Names.for(cases.flat_map(&:subject_user_ids) +
        cases.flat_map(&:assignee_user_ids))
    end

    def create
      ids = ticked_ids
      return refuse("tick the cases to mark as duplicates") if ids.empty?

      if params[:duplicate_of].present? && chosen_target.nil?
        return refuse("that case is gone, so there is nothing to keep")
      end
      if chosen_target.nil? && ids.size < 2
        return refuse("tick at least two cases: the oldest stays open, " \
          "the rest close as duplicates of it")
      end

      target = chosen_target || oldest_of(ids)
      return refuse("those cases are gone") if target.nil?

      root = Case.root_for(target.id)
      marked = mark(ids - [root], root)

      if marked.zero?
        refuse("nothing to mark: those cases are resolved already")
      else
        redirect_to fd_cases_path(query_params), notice: outcome(marked, ids, root)
      end
    end

    private

    def ticked_ids
      Array(params[:case_ids]).map(&:to_i).reject(&:zero?).uniq
    end

    def candidate_page
      shared, subject, seen = Case.candidate_parts(@case, @siblings)
      around, more = Case.candidates_around(seen, page: @page, per: PER_PAGE)
      return [[[Case::AROUND, around]].reject { |_, found| found.empty? }, more] if @page > 1

      groups = [["same thread", shared],
                ["also about #{@case.subject_user_ids.any? ? 'the same person' : 'somebody on this case'}",
                 subject],
                [Case::AROUND, around]].reject { |_label, found| found.empty? }
      [groups, more]
    end

    def read_reports(cases)
      ActiveRecord::Associations::Preloader.new(records: cases,
        associations: [:reports, :assignees]).call
      ids = cases.map(&:id)
      @held_counts = IntakeFile.counts_for_cases(ids)
      @cited_words = IntakeShare.first_words_for(ids)
      @channels = ChannelNames.for(@cited_words.values.map(&:channel))
      @violations = Case.violations_for(ids)
      @priors = Case.prior_counts_for(cases.flat_map(&:subject_user_ids))
      @reachable = IntakeConversation.open_ones
        .where(report_id: cases.flat_map { |kase| kase.reports.map(&:id) })
        .pluck(:report_id).to_set
    end

    def found_groups
      found = Search.new(@term, scope: "case", limit: 8).groups
        .flat_map(&:rows).map(&:record)
        .reject { |kase| @case.family_ids.include?(kase.id) }
      found.empty? ? [] : [["matching \"#{@term}\"", found]]
    end

    def query_params
      params.permit(*CaseQuery::KEYS).to_h.compact_blank
    end

    def chosen_target
      return nil if params[:duplicate_of].blank?

      @chosen_target ||= Case.find_by(id: params[:duplicate_of])
    end

    def oldest_of(ids)
      Case.where(id: ids).order(:opened_at, :id).first
    end

    def mark(ids, root)
      now = Time.current
      marked = 0

      writing do
        Case.where(id: ids).unresolved.order(:id).each do |kase|
          rows = Case.where(id: kase.id, resolved_at: nil)
            .update_all(
              resolved_at: now, resolution: "duplicate",
              duplicate_of: root, updated_at: now
            )
          next if rows.zero?

          marked += 1
          audit(kase.reload, "resolved",
            before: { "resolved_at" => nil, "resolution" => nil, "duplicate_of" => nil },
            after: {
              "resolved_at" => kase.resolved_at,
              "resolution" => "duplicate",
              "duplicate_of" => root
            })
        end
      end

      marked
    end

    def outcome(marked, ids, root)
      note = "#{marked} #{'case'.pluralize(marked)} closed as " \
        "#{'duplicate'.pluralize(marked)} of case #{root}, which stays open"
      skipped = ids.reject { |id| id == root }.size - marked
      skipped.positive? ? "#{note}, #{skipped} left alone" : note
    end

    def refuse(message)
      redirect_to fd_cases_path(query_params), alert: message
    end
  end
end
