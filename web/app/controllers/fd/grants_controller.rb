module Fd
  class GrantsController < BaseController
    skip_before_action :needs_the_engine

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    permit "access.grant"

    def create
      user_id = Array(params[:user_id]).first.to_s.strip.upcase
      role = params[:role].to_s
      problem = objection(user_id, role)
      return redirect_to(admin_people_path, alert: problem) if problem

      grant = nil
      writing do
        grant = AccessGrant.give!(user_id, role: role, by: current_staff.user_id,
          reason: params[:reason].to_s.strip.presence)
        audit(grant, "granted",
          after: { "user_id" => user_id, "role" => role, "reason" => grant.reason })
      end

      redirect_to admin_person_path(user_id),
        notice: "#{who(user_id)} is a #{role.tr('_', ' ')}"
    end

    def destroy
      grant = AccessGrant.live.find_by(id: params[:id])
      return redirect_to(admin_people_path, alert: "that grant already ended") if grant.nil?
      return redirect_to(admin_people_path,
        alert: "somebody else has to take yours back") if grant.user_id == current_staff.user_id

      writing do
        grant.take_back!(by: current_staff.user_id)
        audit(grant, "revoked", before: { "role" => grant.role }, after: nil)
      end

      redirect_to admin_people_path, notice: "#{who(grant.user_id)} holds nothing now"
    end

    private

    def who(user_id)
      Names.for([user_id])[user_id]
    end

    def objection(user_id, role)
      return "search for somebody to give it to" unless user_id.match?(MEMBER_ID)
      return "pick a role" unless Permission::ROLES.include?(role)

      nil
    end
  end
end
