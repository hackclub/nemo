module Fd
  class RepliesController < BaseController
    permit "case.reply", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      read = Marks.read(params[:body], aimed: true)
      sent = nil

      writing do
        sent = Outgoing.queue(conversation_for(kase), read.said, mode: mode(read),
          by: current_staff.user_id)
        answered(kase, sent.queued) if sent.queued
      end

      return redirect_to(back_to(kase), alert: sent.problem) if sent.problem

      respond_to do |format|
        format.turbo_stream { render turbo_stream: CaseChatBroadcast.tag(kase.id) }
        format.html { redirect_to back_to(kase), notice: "on its way to them" }
      end
    end

    private

    def conversation_for(kase)
      family = IntakeConversation.for_case(kase.family_ids).open_ones
      family.find_by(id: params[:conversation_id]) || family.first
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
