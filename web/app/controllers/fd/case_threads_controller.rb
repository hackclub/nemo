module Fd
  class CaseThreadsController < BaseController
    permit "case.read", only: :show
    permit "case.open", on: -> { Case.find(params[:case_id]) }, only: [:create, :destroy]

    def show
      @case = Case.find(params[:case_id])
      @thread = CaseThread.visible.where(case_id: @case.family_ids).find_by(id: params[:id])
      return head(:not_found) if @thread.nil?

      @slack_message = Slack::Message.at(@thread.channel_id, @thread.thread_ts)
      message = @slack_message.message || {}
      @author_id = message["user"]
      @names = Names.for([@author_id, *Mentions.ids(message["text"])].compact)
      @channels = ChannelNames.for([@thread.channel_id, *Mentions.channel_ids(message["text"])])
      @emoji = Slack::Emoji.for(Slack::RichText.emoji_names(@slack_message.message))
      render layout: false
    end

    def create
      kase = Case.find(params[:case_id])
      link = params[:link].to_s.strip
      ref = SlackLink.parse(link)
      if ref.nil?
        field_error!(:link, link.blank? ? "Enter a Slack link" : "Not a Slack message link", link)
        return redirect_to(fd_case_path(kase, tab: "threads", do: "thread"))
      end

      if CaseThread.visible.exists?(case_id: kase.family_ids, channel_id: ref.channel_id,
        thread_ts: ref.thread_ts)
        return redirect_to(fd_case_path(kase, tab: "threads"), alert: "Thread already on this case")
      end

      writing { attach(kase, ref) }
      redirect_to fd_case_path(kase, tab: "threads"), notice: "Slack thread added"
    rescue ActiveRecord::RecordNotUnique
      redirect_to fd_case_path(kase, tab: "threads"), alert: "Thread already on this case"
    end

    def destroy
      kase = Case.find(params[:case_id])
      thread = CaseThread.visible.where(case_id: kase.family_ids).find_by(id: params[:id])
      return redirect_to(fd_case_path(kase, tab: "threads"), alert: "Thread not on this case") if thread.nil?

      writing do
        thread.update!(removed_at: Time.current, removed_by: current_account.user_id)
        audit(thread, "detached", entity_id: thread.case_id, before: thread.audit_values)
      end

      flash[:action] = { "label" => "Undo", "href" => fd_case_threads_path(kase), "method" => "post",
                         "params" => { "link" => SlackLink.url_for(thread.channel_id, thread.thread_ts) } }
      redirect_to fd_case_path(kase, tab: "threads"), notice: "Slack thread removed"
    end

    private

    def attach(kase, ref)
      thread = CaseThread.find_by(case_id: kase.id, channel_id: ref.channel_id, thread_ts: ref.thread_ts)
      if thread
        thread.update!(removed_at: nil, removed_by: nil)
      else
        thread = CaseThread.create!(case_id: kase.id, channel_id: ref.channel_id, thread_ts: ref.thread_ts,
          kind: CaseThread.kind_for(ref.channel_id), is_primary: false,
          added_by: current_account.user_id, added_at: Time.current)
      end
      audit(thread, "attached", entity_id: kase.id, after: thread.audit_values)
    end
  end
end
