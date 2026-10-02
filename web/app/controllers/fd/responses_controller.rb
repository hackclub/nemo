module Fd
  class ResponsesController < BaseController
    permit "app.configure"

    LONGEST = 4000
    SLOWEST = 365

    def autoresponse
      problem = autoresponse_objection
      return refuse(problem) if problem

      writing do
        tune(AppSetting.flip(AppSetting::AUTORESPONSE_ON, params[:on].present?,
          by: current_account.user_id))
        tune(AppSetting.set_words(AppSetting::AUTORESPONSE_EMOJI, params[:emoji],
          by: current_account.user_id))
        keep_if_said(AppSetting::AUTORESPONSE_CHANNEL, channel_id)
        keep_if_said(AppSetting::AUTORESPONSE_BODY, body)
        keep_if_said(AppSetting::AUTORESPONSE_COOLDOWN, cooldown.positive? ? cooldown.to_s : "")
      end

      redirect_to here, notice: "the autoresponse is saved"
    end

    def unsub_shield
      link = params[:link].to_s.strip
      return refuse("that is not a link") if link.present? && !link.match?(%r{\Ahttps?://})

      writing do
        tune(AppSetting.flip(AppSetting::UNSUB_SHIELD_ON, params[:on].present?,
          by: current_account.user_id))
        keep_if_said(AppSetting::UNSUB_SHIELD_LINK, link)
      end

      redirect_to here, notice: "the unsubscribe shield is saved"
    end

    private

    def here
      fd_configuration_path(tab: "responses")
    end

    def channel_id
      @channel_id ||= params[:channel_id].to_s.strip
    end

    def body
      params[:body].to_s.strip
    end

    def cooldown
      params[:cooldown_days].to_s.strip.to_i
    end

    def autoresponse_objection
      return nil if params[:on].blank?

      return "say what to answer with" if body.blank?
      return "keep it under #{LONGEST} characters" if body.length > LONGEST
      return "pick which channel to watch" if channel_id.blank?
      return "#{channel_id} is not a channel" unless known?(channel_id)
      return "pick at least one emoji" if wanted_emoji.empty?
      return "say how many days, from 1 to #{SLOWEST}" unless cooldown.between?(1, SLOWEST)

      nil
    end

    def wanted_emoji
      Array(params[:emoji]).flat_map { |one| one.to_s.split(",") }
        .map { |one| one.strip.delete_prefix(":").delete_suffix(":") }.reject(&:blank?)
    end

    def known?(said)
      Analytics::DimChannel.where(channel_id: said).exists?
    end

    def keep_if_said(key, value)
      return nil if value.blank?

      tune(AppSetting.keep(key, value, by: current_account.user_id))
    end

    def tune(setting)
      audit(setting, "tuned") if setting
      setting
    end

    def refuse(why)
      redirect_to here, alert: why
    end
  end
end
