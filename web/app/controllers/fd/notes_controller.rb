module Fd
  class NotesController < BaseController
    MAX_LENGTH = 5_000

    permit "case.note"

    def create
      kase = Case.find(params[:case_id])
      body = Mentions.normalise(params[:body].to_s.strip)
      about = params[:about].to_s
      standing = about.present? && about != "case"

      problem = objection(kase, body, standing, about)
      return redirect_to(back_to(kase, standing, about), alert: problem) if problem

      writing do
        note = Note.create!(
          case_id: standing ? nil : kase.id,
          subject_user_id: standing ? about : nil,
          body: body,
          author: current_staff.user_id
        )
        audit(note, "noted")
      end

      redirect_to back_to(kase, standing, about), notice: notice_for(kase, standing, about)
    end

    def destroy
      kase = Case.find(params[:case_id])
      now = Time.current
      removed = false
      about = on_this_page(kase).find_by(id: params[:id])&.subject_user_id
      standing = about.present?

      writing do
        rows = on_this_page(kase)
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
        redirect_to back_to(kase, standing, about), notice: "note removed"
      else
        redirect_to back_to(kase, standing, about),
          alert: "only whoever wrote a note can remove it"
      end
    end

    private

    def back_to(kase, standing, about)
      return fd_case_path(kase, tab: "people", person: about) if standing

      fd_case_path(kase, tab: "notes")
    end

    def on_this_page(kase)
      Note.where(case_id: kase.id)
        .or(Note.standing.where(subject_user_id: kase.subject_user_ids))
    end

    def objection(kase, body, standing, about)
      return "write the note before saving it" if body.blank?
      return "that note is too long, keep it under #{MAX_LENGTH} characters" if body.length > MAX_LENGTH
      if standing && !kase.subject_user_ids.include?(about)
        return "that member is not a subject of this case"
      end

      nil
    end

    def notice_for(kase, standing, about)
      standing ? "noted against @#{about}" : "note added to case #{kase.id}"
    end
  end
end
