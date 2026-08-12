module Fd
  class NotesController < BaseController
    MAX_LENGTH = 5_000

    def create
      kase = Case.find(params[:case_id])
      body = params[:body].to_s.strip
      standing = params[:scope] == "member"

      problem = objection(kase, body, standing)
      return redirect_to(fd_case_path(kase), alert: problem) if problem

      writing do
        note = Note.create!(
          case_id: standing ? nil : kase.id,
          subject_user_id: standing ? kase.subject_user_id : nil,
          body: body,
          author: current_staff.user_id
        )
        audit(note, "noted")
      end

      redirect_to fd_case_path(kase), notice: notice_for(kase, standing)
    end

    private

    def objection(kase, body, standing)
      return "write the note before saving it" if body.blank?
      return "that note is too long, keep it under #{MAX_LENGTH} characters" if body.length > MAX_LENGTH
      return "this case has no subject, so there is nobody to note this against" if standing && kase.subject_user_id.blank?

      nil
    end

    def notice_for(kase, standing)
      standing ? "noted against @#{kase.subject_user_id}" : "note added to case #{kase.id}"
    end
  end
end
