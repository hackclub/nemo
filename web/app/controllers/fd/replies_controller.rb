module Fd
  class RepliesController < BaseController
    include ResolvesFromChat

    permit "case.reply", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      return resolve_from_chat(kase) if Marks.resolve_command?(params[:body], to_reporter: true)

      parsed = Marks.read(params[:body], to_reporter: true)
      sent = nil

      writing do
        sent = Outgoing.queue(conversation_for(kase), parsed.body, mode: mode(parsed),
          by: current_account.user_id, conversation_selected: params[:conversation_id].present?)
        audit_reply(kase, sent.queued) if sent.queued
      end

      return redirect_to(back_to(kase), alert: sent.problem) if sent.problem

      respond_to do |format|
        format.turbo_stream { render turbo_stream: CaseChatBroadcast.tag(kase.id) }
        format.html do
          redirect_to back_to(kase), notice: "Reply queued"
        end
      end
    end

    private

    def conversation_for(kase)
      conversations = IntakeConversation.for_case(kase.family_ids).open
      return conversations.first if params[:conversation_id].blank?

      conversations.find_by(id: params[:conversation_id])
    end

    def audit_reply(kase, queued)
      audit(queued.conversation.report, "answered", entity_id: kase.id,
        after: { "outbox_id" => queued.id, "mode" => queued.mode })
    end

    def back_to(kase)
      fd_case_path(kase, tab: "report")
    end

    def mode(parsed)
      parsed.signed? && params[:anon] != "1" ? "signed" : "body"
    end
  end
end
