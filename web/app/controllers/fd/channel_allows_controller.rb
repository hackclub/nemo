module Fd
  class ChannelAllowsController < BaseController
    permit "channel.guard"

    MEMBER_ID = /\A[UWB][A-Z0-9]{2,}\z/

    def create
      guard = live_guard
      return refuse("this channel is not guarded") if guard.nil?

      wanted = asked_for
      return refuse("say which bot to allow") if wanted.empty?
      unless wanted.all? { |id| id.match?(MEMBER_ID) }
        return refuse("that does not look like a bot id")
      end

      added = []
      writing do
        wanted.each do |subject_id|
          next if guard.allows.exists?(subject_id: subject_id)

          allow = guard.allows.create!(subject_id: subject_id, label: label_for(subject_id),
            added_by: current_account.user_id)
          audit(allow, "added", entity_id: guard.id)
          added << subject_id
        end
      end

      redirect_to fd_channel_path(channel_id), notice: allowed_notice(added, wanted)
    end

    def destroy
      guard = live_guard
      return refuse("this channel is not guarded") if guard.nil?

      allow = guard.allows.find_by(subject_id: params[:id].to_s.strip.upcase)
      return refuse("that bot is not on the list") if allow.nil?

      writing do
        audit(allow, "removed", entity_id: guard.id,
          before: { "subject_id" => allow.subject_id, "label" => allow.label }, after: nil)
        allow.destroy!
      end

      redirect_to fd_channel_path(channel_id),
        notice: "#{allow.name} is off the list, and will be put out if it posts"
    end

    private

    def channel_id
      @channel_id ||= params[:channel_id].to_s.strip.upcase
    end

    def live_guard
      @live_guard ||= ChannelGuard.live_for(channel_id)
    end

    def asked_for
      raw = params[:subject_ids].presence || [params[:subject_id]]
      Array(raw).map { |id| id.to_s.strip.delete_prefix("@").upcase }.reject(&:blank?).uniq
    end

    def label_for(subject_id)
      Member.find_by(user_id: subject_id)&.name
    end

    def allowed_notice(added, wanted)
      return "everything you picked was already allowed here" if added.empty?

      who = added.map { |id| label_for(id) || id }.to_sentence
      note = "#{who} may post here"
      added.size < wanted.size ? "#{note}, the rest were already on the list" : note
    end

    def refuse(why)
      redirect_to fd_channel_path(channel_id), alert: why
    end
  end
end
