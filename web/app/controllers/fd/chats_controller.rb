module Fd
  class ChatsController < BaseController
    include ResolvesFromChat

    permit "case.chat", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      return resolve_from_chat(kase) if Marks.resolve_command?(params[:body])

      parsed = Marks.read(Mentions.normalise(params[:body].to_s.strip))

      return send_to_reporter(kase, parsed) if parsed.to_reporter?

      error = validation_error(parsed.body)
      return redirect_to(back_to(kase), alert: error) if error

      line = writing { create_chat_line(kase, parsed.body) }
      SlackPost.post_to_thread(line) if line.mirrored_as == "user"

      respond(kase)
    end

    private

    def conversation_for(kase)
      conversations = IntakeConversation.for_case(kase.family_ids).open
      return conversations.first if params[:conversation_id].blank?

      conversations.find_by(id: params[:conversation_id])
    end

    def send_to_reporter(kase, parsed)
      denied_reason = Access.why_not(current_account, "case.reply", kase)
      return redirect_to(back_to(kase), alert: denied_reason) if denied_reason

      sent = nil
      writing do
        sent = Outgoing.queue(conversation_for(kase), parsed.body, mode: mode(parsed),
          by: current_account.user_id, conversation_selected: params[:conversation_id].present?)
        audit_reply(kase, sent.queued) if sent.queued
      end

      return redirect_to(back_to(kase), alert: sent.problem) if sent.problem

      respond(kase)
    end

    def audit_reply(kase, queued)
      audit(queued.conversation.report, "answered", entity_id: kase.id,
        after: { "outbox_id" => queued.id, "mode" => queued.mode })
    end

    def mode(parsed)
      parsed.signed? && params[:anon] != "1" ? "signed" : "body"
    end

    def create_chat_line(kase, body)
      CaseChat.create!(
        case_id: kase.id,
        author_user_id: current_account.user_id,
        body: body,
        source_app: Audit::SOURCE_APP,
        mirrored_as: (SlackPost.claimable?(kase.id, current_account.user_id) ? "user" : nil)
      )
    end

    def respond(kase)
      respond_to do |format|
        format.turbo_stream { render turbo_stream: CaseChatBroadcast.tag(kase.id) }
        format.html { redirect_to back_to(kase) }
      end
    end

    def back_to(kase)
      fd_case_path(kase, tab: "report")
    end

    def validation_error(body)
      return "Enter a message" if body.blank?
      return "Keep it under #{CaseChat::MAX_LENGTH} characters" if
        body.length > CaseChat::MAX_LENGTH

      nil
    end
  end
end
