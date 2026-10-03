module Fd
  class ChannelGuardsController < BaseController
    permit "channel.guard"

    def create
      return refuse("That is not a valid guard kind") unless ChannelGuard.kind?(kind)
      return refuse("This channel is already guarded") if live_guard

      problem = settings_objection
      return refuse(problem) if problem

      writing do
        guard = ChannelGuard.create!(kind: kind, channel_id: channel_id,
          settings: asked_settings, opened_by: current_account.user_id)
        audit(guard, "opened", after: guard.settings)
      end

      redirect_to here, notice: "#{guard_label_text.upcase_first} turned on"
    end

    def update
      guard = live_guard
      return refuse("This channel is not guarded that way") if guard.nil?

      problem = settings_objection
      return refuse(problem) if problem

      was = guard.settings
      writing do
        guard.update!(settings: was.merge(asked_settings), updated_at: Time.current)
        audit(guard, "tuned", before: was, after: guard.settings)
      end

      redirect_to here, notice: "#{guard_label_text.upcase_first} updated"
    end

    def destroy
      guard = live_guard
      return refuse("This channel is not guarded that way") if guard.nil?

      writing do
        guard.update!(state: "lifted", lifted_at: Time.current,
          lifted_by: current_account.user_id)
        audit(guard, "lifted")
      end

      redirect_to here, notice: "#{guard_label_text.upcase_first} turned off; the list is kept"
    end

    private

    def channel_id
      @channel_id ||= params[:channel_id].to_s.strip.upcase
    end

    def kind
      @kind ||= params[:kind].to_s
    end

    def live_guard
      @live_guard ||= ChannelGuard.live_for(channel_id, kind: kind)
    end

    def guard_label_text
      FdChannelsHelper::GUARD_LABELS.fetch(kind, kind).downcase
    end

    def here
      fd_channel_path(channel_id, tab: kind)
    end

    def asked_settings
      case kind
      when ChannelGuard::SLOWMODE
        { "seconds" => seconds, "threads" => params[:threads].present? }
      when ChannelGuard::ACCOUNT_AGE
        { "min_age_days" => min_age_days }
      else
        {}
      end
    end

    def seconds
      given = params[:seconds].to_s.strip
      given.present? ? given.to_i : ChannelGuard::SECONDS_TO_START
    end

    def min_age_days
      given = params[:min_age_days].to_s.strip
      given.present? ? given.to_i : ChannelGuard::DAYS_TO_START
    end

    def settings_objection
      case kind
      when ChannelGuard::SLOWMODE
        return nil if params[:seconds].to_s.strip.blank?
        return "say how many seconds, from 1 to #{ChannelGuard::SLOWEST}" unless
          seconds.between?(1, ChannelGuard::SLOWEST)
      when ChannelGuard::ACCOUNT_AGE
        return nil if params[:min_age_days].to_s.strip.blank?
        return "say how many days, from 1 to #{ChannelGuard::OLDEST}" unless
          min_age_days.between?(1, ChannelGuard::OLDEST)
      end

      nil
    end

    def refuse(why)
      redirect_to fd_channel_path(channel_id, tab: ChannelGuard.kind?(kind) ? kind : nil),
        alert: why
    end
  end
end
