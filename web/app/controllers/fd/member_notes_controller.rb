module Fd
  class MemberNotesController < BaseController
    permit "member.note"

    def create
      user_id = params[:member_id].to_s.upcase
      body = Mentions.normalise(params[:body].to_s.strip)

      problem = objection(body)
      if problem
        return redirect_to(fd_member_path(user_id, show: "notes"),
          alert: (problem unless flash[:wrong]))
      end

      writing do
        note = Note.create!(subject_user_id: user_id, body: body, author: current_staff.user_id)
        audit(note, "noted")
      end

      flash[:did] = { "label" => "See their record", "href" => fd_member_path(user_id) }
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
        flash[:said] = "It stays in the audit trail, but it no longer follows them to a case."
        redirect_to fd_member_path(user_id, show: "notes"), notice: "Note removed"
      else
        redirect_to fd_member_path(user_id, show: "notes"), alert: "only whoever wrote a note can remove it"
      end
    end

    private

    def objection(body)
      return wrong!(:body, "Write the note before saving it.") if body.blank?

      most = NotesController::MAX_LENGTH
      if body.length > most
        return wrong!(:body, "Keep it under #{most} characters. That one is #{body.length}.", body)
      end

      nil
    end
  end
end
