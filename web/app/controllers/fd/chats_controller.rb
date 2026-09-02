module Fd
  class ChatsController < BaseController
    permit "case.chat", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      read = Marks.read(Mentions.normalise(params[:body].to_s.strip))

      return send_it(kase, read) if read.to_reporter?

      problem = objection(read.said)
      return redirect_to(back_to(kase), alert: problem) if problem

      said = writing { keep(kase, read.said) }
      SlackPost.carry(said) if said.mirrored_as == "user"

      answer(kase)
    end

    private

    def conversation_for(kase)
      family = IntakeConversation.for_case(kase.family_ids).open_ones
      return family.first if params[:conversation_id].blank?

      family.find_by(id: params[:conversation_id])
    end

    def send_it(kase, read)
      why_not = Access.why_not(current_staff, "case.reply", kase)
      return redirect_to(back_to(kase), alert: why_not) if why_not

      sent = nil
      writing do
        sent = Outgoing.queue(conversation_for(kase), read.said, mode: mode(read),
          by: current_staff.user_id, asked: params[:conversation_id].present?)
        answered(kase, sent.queued) if sent.queued
      end

      return redirect_to(back_to(kase), alert: sent.problem) if sent.problem

      answer(kase)
    end

    def answered(kase, queued)
      audit(queued.conversation.report, "answered", entity_id: kase.id,
        after: { "outbox_id" => queued.id, "mode" => queued.mode })
    end

    def mode(read)
      read.signed? && params[:anon] != "1" ? "signed" : "body"
    end

    def keep(kase, body)
      CaseChat.create!(
        case_id: kase.id,
        author_user_id: current_staff.user_id,
        body: body,
        source_app: Audit::SOURCE_APP,
        mirrored_as: (SlackPost.claimable?(kase.id, current_staff.user_id) ? "user" : nil)
      )
    end

    def answer(kase)
      respond_to do |format|
        format.turbo_stream { render turbo_stream: CaseChatBroadcast.tag(kase.id) }
        format.html { redirect_to back_to(kase) }
      end
    end

    def back_to(kase)
      fd_case_path(kase, tab: "report")
    end

    def objection(body)
      return "write something first" if body.blank?
      return "that is too long, keep it under #{CaseChat::MAX_LENGTH}" if
        body.length > CaseChat::MAX_LENGTH

      nil
    end
  end
end
