module Fd
  class CitationsController < BaseController
    def create
      kase = Case.find(params[:case_id])
      said = held_message(kase, params[:thread_message_id])

      return refuse(kase, "that message is not on this case") if said.nil?

      problem = not_yours(kase)
      return redirect_to(fd_case_path(kase), alert: problem) if problem

      writing do
        flag = CaseCitation.create!(case_id: kase.id, thread_message_id: said.id,
          flagged_by: current_staff.user_id)
        audit(flag, "flagged", entity_id: kase.id)
      end

      redirect_to case_url_for(kase, said), notice: "message flagged"
    rescue ActiveRecord::RecordNotUnique
      redirect_to case_url_for(kase, said), notice: "that message was already flagged"
    end

    def destroy
      kase = Case.find(params[:case_id])
      flag = kase.citations.find_by(id: params[:id])

      return refuse(kase, "that flag is not on this case") if flag.nil?

      problem = not_yours(kase)
      return redirect_to(fd_case_path(kase), alert: problem) if problem

      said = flag.message
      writing do
        audit(flag, "unflagged", entity_id: kase.id,
          before: { "thread_message_id" => flag.thread_message_id }, after: nil)
        flag.destroy!
      end

      redirect_to case_url_for(kase, said), notice: "flag taken off"
    end

    private

    def case_url_for(kase, said)
      fd_case_path(kase, thread: thread_of(kase, said), person: params[:person].presence)
    end

    def held_message(kase, id)
      return nil if id.blank?

      ThreadMessage.for_threads(kase.threads.to_a).find_by(id: id)
    end

    def thread_of(kase, said)
      return nil if said.nil?

      kase.threads.find { |thread| thread.coordinates == said.coordinates }&.id
    end

    def refuse(kase, alert)
      redirect_to fd_case_path(kase), alert: alert
    end
  end
end
