module Fd
  class RepliesController < BaseController
    permit "case.reply", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      body = params[:body].to_s.strip
      conversation = IntakeConversation.for_case(kase.id).open_ones.first

      problem = objection(conversation, body)
      return redirect_to(back_to(kase), alert: problem) if problem

      writing do
        queued = IntakeOutbox.create!(
          conversation_id: conversation.id,
          kind: "reply",
          body: body,
          mode: mode,
          requested_by: current_staff.user_id
        )
        audit(conversation.report, "answered", entity_id: kase.id,
          after: { "outbox_id" => queued.id, "mode" => queued.mode })
      end

      respond_to do |format|
        format.turbo_stream { render turbo_stream: CaseChatBroadcast.tag(kase.id) }
        format.html { redirect_to back_to(kase), notice: "on its way to them" }
      end
    end

    private

    def back_to(kase)
      fd_case_path(kase, tab: "report")
    end

    def mode
      IntakeOutbox::MODES.include?(params[:mode]) ? params[:mode] : "body"
    end

    def objection(conversation, body)
      return "write something before sending it" if body.blank?
      if body.length > IntakeOutbox::MAX_LENGTH
        return "that is too long to send, keep it under #{IntakeOutbox::MAX_LENGTH} characters"
      end
      return "there is nobody to reply to on this case" if conversation.nil?
      return "that conversation is closed, so nothing can be sent" if conversation.closed?

      nil
    end
  end
end
