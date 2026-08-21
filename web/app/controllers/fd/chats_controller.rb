module Fd
  class ChatsController < BaseController
    permit "case.chat", on: -> { Case.find(params[:case_id]) }

    def create
      kase = Case.find(params[:case_id])
      body = Mentions.normalise(params[:body].to_s.strip)

      problem = objection(body)
      return redirect_to(back_to(kase), alert: problem) if problem

      writing do
        CaseChat.create!(
          case_id: kase.id,
          author_user_id: current_staff.user_id,
          body: body,
          source_app: Audit::SOURCE_APP
        )
      end

      answer(kase)
    end

    private

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
