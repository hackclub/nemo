module Fd
  class ParticipantsController < BaseController
    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    permit "case.people", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      wanted = asked_for
      role = params[:role].to_s
      detail = role == "involved" ? params[:detail].to_s.strip : ""

      problem = objection(wanted, role)
      return redirect_to(fd_case_path(kase, tab: "people"), alert: problem) if problem

      added = []
      already = []

      writing do
        wanted.each do |user_id|
          ActiveRecord::Base.transaction(requires_new: true) do
            person = kase.participants.create!(user_id: user_id, role: role,
              detail: detail.presence)
            audit(person, "attached", entity_id: kase.id)
          end
          added << user_id
        rescue ActiveRecord::RecordNotUnique
          already << user_id
        end
      end

      redirect_to fd_case_path(kase, tab: "people"), notice: added_notice(role, added, already)
    end

    def destroy
      kase = Case.find(params[:case_id])
      person = CaseParticipant.where(case_id: kase.family_ids)
        .find_by(user_id: params[:id], role: params[:role])

      if person.nil?
        return redirect_to(fd_case_path(kase, tab: "people"), alert: "they are not on this case")
      end

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

      redirect_to fd_case_path(kase, tab: "people"),
        notice: "@#{person.user_id} taken off the case"
    end

    private

    def asked_for
      raw = params[:user_ids].presence || [params[:user_id]]
      Array(raw).map { |id| id.to_s.strip.delete_prefix("@").upcase }.reject(&:blank?).uniq
    end

    def objection(wanted, role)
      return "say who to add" if wanted.empty?
      unless wanted.all? { |id| id.match?(MEMBER_ID) }
        return "that does not look like a Slack member id"
      end
      "pick how they were on this case" unless CaseParticipant::ROLES.include?(role)
    end

    def role_word(role)
      role == "involved" ? "involved" : "the #{role}"
    end

    def added_notice(role, added, already)
      return "everybody you picked was already on this case, nothing changed" if added.empty?

      who = added.map { |id| "@#{id}" }.to_sentence
      note = case role
      when "subject" then "the case is now also about #{who}"
      when "reporter" then "#{who} recorded as reporting it"
      else "#{who} added to who else is logged"
      end
      already.any? ? "#{note}, #{already.size} already there" : note
    end
  end
end
