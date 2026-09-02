module Fd
  class RepliesController < BaseController
    permit "case.reply", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      read = Marks.read(params[:body], aimed: true)
      sent = nil

      writing do
        sent = Outgoing.queue(conversation_for(kase), read.said, mode: mode(read),
          by: current_staff.user_id, asked: params[:conversation_id].present?)
        answered(kase, sent.queued) if sent.queued
      end

      return redirect_to(back_to(kase), alert: sent.problem) if sent.problem

      respond_to do |format|
        format.turbo_stream { render turbo_stream: CaseChatBroadcast.tag(kase.id) }
        format.html do
          flash[:said] = "It goes out as a DM. Your name is on it either way."
          redirect_to back_to(kase), notice: "Reply on its way to the reporter"
        end
      end
    end

    private

    def conversation_for(kase)
      family = IntakeConversation.for_case(kase.family_ids).open_ones
      return family.first if params[:conversation_id].blank?

      family.find_by(id: params[:conversation_id])
    end

    def answered(kase, queued)
      audit(queued.conversation.report, "answered", entity_id: kase.id,
        after: { "outbox_id" => queued.id, "mode" => queued.mode })
    end

    def back_to(kase)
      fd_case_path(kase, tab: "report")
    end

    def mode(read)
      read.signed? && params[:anon] != "1" ? "signed" : "body"
    end
  end
end
