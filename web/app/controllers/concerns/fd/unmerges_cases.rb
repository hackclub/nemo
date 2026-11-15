module Fd
  module UnmergesCases
    private

    def unmerge(kase)
      unmerged = kase.unmerge!
      return nil if unmerged.nil?

      audit(kase, "unmerged", before: unmerged.before, after: unmerged.after)
      if unmerged.removed_tags.any?
        audit(CaseTag.new(case_id: unmerged.into_case_id), "removed", entity_id: unmerged.into_case_id,
          before: { "tags" => unmerged.removed_tags.map(&:name), "source_case_ids" => [kase.id] })
      end
      reopen_reports(kase) if unmerged.reopened?
      unmerged
    end

    def reopen_reports(kase)
      CaseReport.where(case_id: Case.family_of(kase.id)).where.not(closed_at: nil).find_each do |report|
        previous_closure = { "closed_at" => report.closed_at, "closed_by" => report.closed_by }
        report.update!(closed_at: nil, closed_by: nil)
        audit(report, "reopened", entity_id: kase.id,
          before: previous_closure, after: { "closed_at" => nil, "closed_by" => nil })
      end
    end
  end
end
