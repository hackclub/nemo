module Fd
  class PhotoRemovalsController < BaseController
    permit "member.guard"

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/
    EVIDENCE_POLICY = "default-src 'none'; sandbox".freeze

    def create
      return redirect_to(fd_members_path, alert: "#{member_id} is not a member id") unless member_id.match?(MEMBER_ID)

      removal = nil
      writing do
        removal = PhotoRemoval.queue!(member_id: member_id, asked_by: current_account.user_id,
          reason: params[:reason])
        audit(removal, "queued", subject_user_id: member_id, after: { "member_id" => member_id }) if removal
      end

      if removal.nil?
        return redirect_to fd_member_path(member_id),
          alert: "Pfp removal already queued for #{display_name}"
      end

      redirect_to fd_member_path(member_id), notice: "Pfp removal queued for #{display_name}"
    end

    def show
      evidence = PhotoRemoval.for_member(member_id).find(params[:id]).evidence
      return head :not_found if evidence.nil?

      response.headers["Content-Security-Policy"] = EVIDENCE_POLICY
      send_data evidence.image, type: evidence.content_type, filename: "pfp-#{evidence.removal_id}",
        disposition: evidence.inline? ? "inline" : "attachment"
    end

    private

    def member_id = params[:member_id].to_s.upcase

    def display_name = Names.for([member_id])[member_id]
  end
end
