module Fd
  class MergesController < BaseController
    permit "case.resolve"

    PER_PAGE = 8

    def show
      @case = Case.find(params[:id])
      @term = params[:q].to_s.strip
      @page = [params[:page].to_i, 1].max
      @siblings = @case.sibling_cases.includes(:subjects).oldest_first.to_a
      @groups, @more = @term.present? ? [search_groups, false] : candidate_page
      @candidates = @groups.flat_map(&:last)
      preload_reports(@candidates)
      @names = Names.for((@candidates + [@case])
        .flat_map(&:subject_user_ids) + [@case.opened_by] +
        @candidates.flat_map(&:assignee_user_ids) +
        @candidates.map(&:opened_by) +
        @candidates.flat_map { |kase| kase.reports.map(&:reporter_user_id) } +
        @preview_user_ids)
      render "more", layout: false if @page > 1
    end

    def confirm
      ids = selected_case_ids
      return redirect_with_alert("Select at least two cases to merge") if ids.size < 2

      @query_params = query_params
      cases = Case.where(id: ids).includes(:subjects, :assignees, :reports, :participants)
        .oldest_first.to_a
      return redirect_with_alert("Cases not found") if cases.size < 2

      @plan = MergePlan.over(cases, primary: params[:keep])
      @names = Names.for(cases.flat_map(&:subject_user_ids) +
        cases.flat_map(&:assignee_user_ids))
    end

    def create
      ids = selected_case_ids
      return redirect_with_alert("Select cases") if ids.empty?

      if params[:duplicate_of].present? && selected_target.nil?
        return redirect_with_alert("Case not found")
      end
      if selected_target.nil? && ids.size < 2
        return redirect_with_alert("Select at least two cases")
      end

      target = selected_target || oldest_of(ids)
      return redirect_with_alert("Cases not found") if target.nil?

      root = Case.root_for(target.id)
      marked = mark_duplicates(ids - [root], root)

      if marked.zero?
        redirect_with_alert("Cases already merged")
      else
        redirect_to fd_cases_path(query_params), notice: merge_notice(marked, ids, root)
      end
    end

    private

    def selected_case_ids
      Array(params[:case_ids]).map(&:to_i).reject(&:zero?).uniq
    end

    def candidate_page
      shared, subject, excluded_ids = Case.candidate_parts(@case, @siblings)
      nearby, more = Case.nearby_candidates(excluded_ids, page: @page, per: PER_PAGE)
      return [[[Case::NEARBY_GROUP, nearby]].reject { |_, cases| cases.empty? }, more] if @page > 1

      groups = [["Same thread", shared],
                [@case.subject_user_ids.any? ? "Same subject" : "Same participant",
                 subject],
                [Case::NEARBY_GROUP, nearby]].reject { |_label, cases| cases.empty? }
      [groups, more]
    end

    def preload_reports(cases)
      ActiveRecord::Associations::Preloader.new(records: cases,
        associations: [:reports, :assignees, { case_tags: :tag }]).call
      ids = cases.map(&:id)
      previews = QueuePreviews.for(cases)
      @attachment_counts = previews.attachment_counts
      @cited_words = previews.cited
      @case_roots = previews.roots
      @preview_user_ids = previews.user_ids
      @channels = ChannelNames.for(previews.channel_ids)
      @violations = Case.violations_for(ids)
      @priors = Case.prior_counts_for(cases.flat_map(&:subject_user_ids))
      @reachable_report_ids = IntakeConversation.open
        .where(report_id: cases.flat_map { |kase| kase.reports.map(&:id) })
        .pluck(:report_id).to_set
    end

    def search_groups
      matches = Search.new(@term, scope: "case", limit: 8).groups
        .flat_map(&:rows).map(&:record)
        .reject { |kase| @case.family_ids.include?(kase.id) }
      matches.empty? ? [] : [["Matching \"#{@term}\"", matches]]
    end

    def query_params
      params.permit(*CaseQuery::KEYS).to_h.compact_blank
    end

    def selected_target
      return nil if params[:duplicate_of].blank?

      @selected_target ||= Case.find_by(id: params[:duplicate_of])
    end

    def oldest_of(ids)
      Case.where(id: ids).order(:opened_at, :id).first
    end

    def mark_duplicates(ids, root)
      now = Time.current
      marked = 0
      marked_ids = []

      writing do
        Case.where(id: ids).where.not(id: root).lock.order(:id).each do |kase|
          next if kase.duplicate_of == root

          before = { "resolved_at" => kase.resolved_at, "resolution" => kase.resolution,
                     "duplicate_of" => kase.duplicate_of }
          kase.update_columns(resolved_at: kase.resolved_at || now, resolution: "duplicate",
            duplicate_of: root, updated_at: now)

          marked += 1
          marked_ids << kase.id
          audit(kase, "resolved", before: before,
            after: {
              "resolved_at" => kase.resolved_at,
              "resolution" => "duplicate",
              "duplicate_of" => root
            })
        end
        repoint_duplicates(marked_ids, root, now)
        copy_tags_to_target(marked_ids, root)
      end

      marked
    end

    def repoint_duplicates(source_case_ids, root, now)
      return if source_case_ids.empty?

      family_ids = source_case_ids.flat_map { |id| Case.family_of(id) } - source_case_ids - [root]
      Case.where(id: family_ids).lock.order(:id).each do |kase|
        before = { "duplicate_of" => kase.duplicate_of }
        kase.update_columns(duplicate_of: root, updated_at: now)
        audit(kase, "merged", before: before, after: { "duplicate_of" => root })
      end
    end

    def copy_tags_to_target(source_case_ids, target_id)
      return if source_case_ids.empty?

      copied_tags = Case.find(target_id).copy_tags_from!(source_case_ids, by: current_account.user_id)
      return if copied_tags.empty?

      audit(CaseTag.new(case_id: target_id), "added", entity_id: target_id,
        after: { "tags" => copied_tags.map(&:name), "source_case_ids" => source_case_ids })
    end

    def merge_notice(marked, ids, root)
      note = "#{marked} #{'case'.pluralize(marked)} marked duplicate of case #{root}"
      skipped = ids.reject { |id| id == root }.size - marked
      skipped.positive? ? "#{note} · #{skipped} skipped" : note
    end

    def redirect_with_alert(message)
      redirect_to fd_cases_path(query_params), alert: message
    end
  end
end
