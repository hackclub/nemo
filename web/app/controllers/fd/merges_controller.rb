module Fd
  class MergesController < BaseController
    def create
      ids = Array(params[:case_ids]).map(&:to_i).reject(&:zero?).uniq
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
        refuse("nothing to mark: they are resolved already, or assigned to somebody else")
      else
        redirect_to fd_cases_path(filter: params[:filter]), notice: outcome(marked, ids, root)
      end
    end

    private

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
            .free_or_assigned_to(current_staff.user_id)
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
              "duplicate_of" => root,
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
      redirect_to fd_cases_path(filter: params[:filter]), alert: message
    end
  end
end
