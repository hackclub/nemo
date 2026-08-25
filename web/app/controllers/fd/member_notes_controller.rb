module Fd
  class MemberNotesController < BaseController
    permit "member.note"

    def create
      user_id = params[:member_id].to_s.upcase
      body = Mentions.normalise(params[:body].to_s.strip)

      problem = objection(body)
      return redirect_to(fd_member_path(user_id, show: "notes"), alert: problem) if problem

      writing do
        note = Note.create!(subject_user_id: user_id, body: body, author: current_staff.user_id)
        audit(note, "noted")
      end

      redirect_to fd_member_path(user_id, show: "notes"),
        notice: "noted, and it follows them to every case"
    end

    def destroy
      user_id = params[:member_id].to_s.upcase
      now = Time.current
      removed = false

      writing do
        rows = Note.for_subject(user_id)
          .where(id: params[:id], deleted_at: nil, author: current_staff.user_id)
          .update_all(deleted_at: now, deleted_by: current_staff.user_id, updated_at: now)
        next if rows.zero?

        removed = true
        note = Note.find(params[:id])
        audit(note, "deleted",
          before: { "deleted_at" => nil },
          after: {
            "deleted_at" => note.deleted_at,
            "deleted_by" => note.deleted_by,
            "body" => note.body
          })
      end

      if removed
        redirect_to fd_member_path(user_id, show: "notes"), notice: "note removed"
      else
        redirect_to fd_member_path(user_id, show: "notes"), alert: "only whoever wrote a note can remove it"
      end
    end

    private

    def objection(body)
      return "write the note before saving it" if body.blank?
      return "that note is too long, keep it under #{NotesController::MAX_LENGTH} characters" if
        body.length > NotesController::MAX_LENGTH

      nil
    end
  end
end
