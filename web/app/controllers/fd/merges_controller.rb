module Fd
  class MergesController < BaseController
    permit "case.resolve"

    class ClosedKeeper < StandardError; end

    def show
      @case = Case.find(params[:id])
      @term = params[:q].to_s.strip
      @siblings = @case.sibling_cases.includes(:subjects).oldest_first.to_a
      @groups = @term.present? ? found_groups : Case.candidate_groups(@case, @siblings)
      @candidates = @groups.flat_map(&:last)
      @names = Names.for((@candidates + [@case])
        .flat_map(&:subject_user_ids) + [@case.opened_by] +
        @candidates.flat_map(&:assignee_user_ids))
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

      root, marked = begin
        mark(ids, target)
      rescue Case::Cycle
        return refuse("case #{target.id}'s merge history loops back on itself; " \
          "this needs a data fix before it can be merged further")
      rescue ClosedKeeper
        return refuse("case #{target.id} is already resolved, so it can't be the case " \
          "that stays open; pick an open case, or reopen this one first")
      end

      if marked.zero?
        if ids.include?(root)
          refuse("case #{root} is already the open case for this family; " \
            "refresh and check what changed")
        else
          refuse("nothing to mark: those cases are resolved already")
        end
      else
        redirect_to fd_cases_path(query_params), notice: outcome(marked, ids, root)
      end
    end

    private

    def ticked_ids
      Array(params[:case_ids]).map(&:to_i).reject(&:zero?).uniq
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

    # Locks every case this request might read or write, in one fixed order, before
    # computing the root - that serializes it against a concurrent merge touching the
    # same cases (e.g. the opposite merge of the same pair) instead of racing it on a
    # stale root_for read, which could otherwise fold two cases into each other.
    def mark(ids, target)
      now = Time.current
      marked = 0
      root = nil

      writing do
        lock_ids = (ids + [target.id]).uniq.sort
        Case.where(id: lock_ids).order(:id).lock.load

        root = Case.root_for(target.id)
        raise ClosedKeeper if Case.where(id: root).unresolved.none?

        Case.where(id: ids - [root]).unresolved.order(:id).each do |kase|
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

      [root, marked]
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
