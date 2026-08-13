module Fd
  class ParticipantsController < BaseController
    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    def create
      kase = Case.find(params[:case_id])
      user_id = params[:user_id].to_s.strip.delete_prefix("@").upcase
      role = params[:role].to_s
      detail = role == "involved" ? params[:detail].to_s.strip : ""

      problem = objection(kase, user_id, role)
      return redirect_to(fd_case_path(kase), alert: problem) if problem

      writing do
        person = kase.participants.create!(user_id: user_id, role: role, detail: detail.presence)
        audit(person, "attached", entity_id: kase.id)
      end

      redirect_to fd_case_path(kase), notice: added_notice(role, user_id)
    rescue ActiveRecord::RecordNotUnique
      redirect_to fd_case_path(kase),
        notice: "@#{user_id} was already on this case as #{role_word(role)}, nothing changed"
    end

    def destroy
      kase = Case.find(params[:case_id])
      person = kase.participants.find_by(user_id: params[:id], role: params[:role])

      return redirect_to(fd_case_path(kase), alert: "they are not on this case") if person.nil?

      problem = not_yours(kase)
      return redirect_to(fd_case_path(kase), alert: problem) if problem

      writing do
        audit(person, "detached", entity_id: kase.id,
          before: {
            "user_id" => person.user_id,
            "role" => person.role,
            "detail" => person.detail
          },
          after: nil)
        person.destroy!
      end

      redirect_to fd_case_path(kase),
        notice: "@#{person.user_id} taken off the case, the trail keeps that they were on it"
    end

    private

    def objection(kase, user_id, role)
      return "say who to add" if user_id.blank?
      return "that does not look like a Slack member id" unless user_id.match?(MEMBER_ID)
      return "pick how they were on this case" unless CaseParticipant::ROLES.include?(role)

      not_yours(kase)
    end

    def role_word(role)
      role == "involved" ? "involved" : "the #{role}"
    end

    def added_notice(role, user_id)
      case role
      when "subject" then "the case is now also about @#{user_id}"
      when "reporter" then "@#{user_id} recorded as reporting it"
      else "@#{user_id} added to who else was involved"
      end
    end
  end
end
