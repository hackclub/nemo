module Fd
  class DecisionThreadsController < BaseController
    def create
      decision = Decision.find(params[:decision_id])
      lines = params[:links].to_s.split("\n").map(&:strip).reject(&:blank?)
      return redirect_to(fd_decision_path(decision), alert: "paste at least one Slack link") if
        lines.empty?

      refs = lines.map { |line| SlackLink.parse(line) }
      wanted = refs.compact.uniq { |ref| [ref.channel_id, ref.thread_ts] }
      held = decision.threads.pluck(:channel_id, :thread_ts)
      fresh = wanted.reject { |ref| held.include?([ref.channel_id, ref.thread_ts]) }

      kind = DecisionThread::KINDS.include?(params[:kind]) ? params[:kind] : "internal"

      writing do
        fresh.each do |ref|
          thread = decision.threads.create!(channel_id: ref.channel_id,
            thread_ts: ref.thread_ts, why: params[:why], kind: kind,
            added_by: current_staff.user_id)
          audit(thread, "attached", entity_id: decision.id)
        end
      end

      redirect_to fd_decision_path(decision),
        notice: linked_notice(fresh.size, wanted.size - fresh.size, refs.count(&:nil?))
    end

    def destroy
      decision = Decision.find(params[:decision_id])
      thread = decision.threads.find_by(id: params[:id])
      return redirect_to(fd_decision_path(decision),
        alert: "that thread is not on this decision") if thread.nil?

      writing do
        audit(thread, "detached", entity_id: decision.id,
          before: { "channel_id" => thread.channel_id, "thread_ts" => thread.thread_ts,
                    "why" => thread.why },
          after: nil)
        thread.destroy!
      end

      redirect_to fd_decision_path(decision), notice: "thread unlinked"
    end

    private

    def linked_notice(linked, already, unreadable)
      parts = [linked.zero? ? "nothing linked" : "#{helpers.pluralize(linked, 'thread')} linked"]
      parts << "#{already} already linked" if already.positive?
      parts << unreadable_note(unreadable) if unreadable.positive?
      parts.join(", ")
    end

    def unreadable_note(count)
      return "one line was not a Slack thread link" if count == 1

      "#{count} lines were not Slack thread links"
    end
  end
end
