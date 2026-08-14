module Fd
  class ThreadsController < BaseController
    permit "case.thread", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      ref = SlackLink.parse(params[:link])
      kind = CaseThread::KINDS.include?(params[:kind]) ? params[:kind] : "evidence"

      problem = objection(kase, ref)
      return redirect_to(fd_case_path(kase), alert: problem) if problem

      writing do
        thread = CaseThread.create!(
          case_id: kase.id,
          channel_id: ref.channel_id,
          thread_ts: ref.thread_ts,
          kind: kind,
          is_primary: first_evidence?(kase, kind),
          added_by: current_staff.user_id
        )
        audit(thread, "attached")
      end

      redirect_to fd_case_path(kase), notice: attached_notice(kind)
    rescue ActiveRecord::RecordNotUnique
      redirect_to fd_case_path(kase), alert: "that thread is already on this case"
    end

    def destroy
      kase = Case.find(params[:case_id])
      thread = kase.threads.find_by(id: params[:id])

      return redirect_to(fd_case_path(kase), alert: "that thread is not on this case") if thread.nil?

      problem = not_yours(kase)
      return redirect_to(fd_case_path(kase), alert: problem) if problem

      writing do
        audit(thread, "detached", entity_id: kase.id,
          before: {
            "channel_id" => thread.channel_id,
            "thread_ts" => thread.thread_ts,
            "kind" => thread.kind
          },
          after: nil)
        thread.destroy!
      end

      redirect_to fd_case_path(kase), notice: "thread detached"
    end

    private

    def objection(kase, ref)
      return "paste a link to a Slack thread in this workspace" if ref.nil?

      not_yours(kase)
    end

    def first_evidence?(kase, kind)
      kind == "evidence" && !kase.threads.evidence.exists?(is_primary: true)
    end

    def attached_notice(kind)
      kind == "internal" ? "internal thread linked, not evidence" : "evidence thread attached"
    end
  end
end
