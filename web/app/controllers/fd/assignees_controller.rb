module Fd
  class AssigneesController < BaseController
    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    permit "case.open", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      wanted = asked_for

      problem = objection(kase, wanted)
      return redirect_to(fd_case_path(kase), alert: problem) if problem

      added = []
      already = []

      writing do
        wanted.each do |user_id|
          ActiveRecord::Base.transaction(requires_new: true) do
            assignee = kase.assign!(user_id, by: current_account.user_id)
            audit(assignee, "attached", entity_id: kase.id)
          end
          added << user_id
        rescue ActiveRecord::RecordNotUnique
          already << user_id
        end
      end

      redirect_to fd_case_path(kase), notice: assigned_notice(added, already)
    end

    def destroy
      kase = Case.find(params[:case_id])
      assignee = kase.assignees.find_by(user_id: params[:id])

      if assignee.nil?
        return redirect_to(fd_case_path(kase), alert: "they are not on this case")
      end

      writing do
        audit(assignee, "detached", entity_id: kase.id,
          before: { "user_id" => assignee.user_id, "assigned_by" => assignee.assigned_by },
          after: nil)
        assignee.destroy!
      end

      redirect_to fd_case_path(kase), notice: "@#{assignee.user_id} taken off the case"
    end

    private

    def asked_for
      raw = params[:user_ids].presence || [params[:user_id]]
      Array(raw).map { |id| id.to_s.strip.delete_prefix("@").upcase }.reject(&:blank?).uniq
    end

    def objection(kase, wanted)
      return "say who to assign" if wanted.empty?
      unless wanted.all? { |id| id.match?(MEMBER_ID) }
        return "that does not look like a Slack member id"
      end
      return "case #{kase.id} is already resolved" if kase.resolved?

      nil
    end

    def assigned_notice(added, already)
      return "everybody you picked was already on this case, nothing changed" if added.empty?

      who = added.map { |id| "@#{id}" }.to_sentence
      note = "#{who} #{added.many? ? "are" : "is"} now on the case"
      already.any? ? "#{note}, #{already.size} already there" : note
    end
  end
end
