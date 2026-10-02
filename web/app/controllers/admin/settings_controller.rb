module Admin
  class SettingsController < BaseController
    SOONEST = Fd::AppSetting::SOONEST

    JOIN_SAID = {
      Fd::AppSetting::ON => "nemo joins every public channel",
      Fd::AppSetting::GUARDED => "nemo joins guarded channels only",
      Fd::AppSetting::OFF => "nemo joins nothing new"
    }.freeze

    def show
      @join_mode = Fd::AppSetting.join_mode
      @soon_hours = Fd::AppSetting.sweep_soon_hours
      @tells_member = Fd::AppSetting.sweep_tells_member?
      @firehouse = Fd::AppSetting.firehouse_channel
      @react_channels = Fd::AppSetting.case_react_channels
      @named = Analytics::DimChannel
        .where(channel_id: ([@firehouse] + @react_channels).compact)
        .index_by(&:channel_id)
    end

    def join_mode
      how = params[:mode].to_s.strip.downcase
      return refuse("that is not a join mode") unless Fd::AppSetting::MODES.include?(how)
      return redirect_to admin_settings_path if how == Fd::AppSetting.join_mode

      keep(Fd::AppSetting.set_join_mode(how, by: current_account.user_id))
      redirect_to admin_settings_path, notice: JOIN_SAID.fetch(how)
    end

    def sweep
      hours = params[:soon_hours].to_s.strip.to_i
      return refuse("say how many hours, from 1 to #{SOONEST}") unless hours.between?(1, SOONEST)

      keep(Fd::AppSetting.keep(Fd::AppSetting::SWEEP_SOON_HOURS, hours.to_s,
        by: current_account.user_id))
      keep(Fd::AppSetting.flip(Fd::AppSetting::SWEEP_TELLS_MEMBER, params[:tells].present?,
        by: current_account.user_id))
      redirect_to admin_settings_path, notice: "the sweep is saved"
    end

    def firehouse
      channel_id = params[:channel_id].to_s.strip
      return refuse("pick a channel") if channel_id.blank?
      return refuse("#{channel_id} is not a channel") unless known?(channel_id)

      keep(Fd::AppSetting.set_firehouse_channel(channel_id, by: current_account.user_id))
      redirect_to admin_settings_path, notice: "guard notices now go to ##{name_of(channel_id)}"
    end

    def add_react
      channel_id = params[:channel_id].to_s.strip
      return refuse("pick a channel") if channel_id.blank?
      return refuse("#{channel_id} is not a channel") unless known?(channel_id)

      held = Fd::AppSetting.case_react_channels
      return redirect_to admin_settings_path if held.include?(channel_id)

      keep(Fd::AppSetting.set_case_react_channels(held + [channel_id],
        by: current_account.user_id))
      redirect_to admin_settings_path,
        notice: "an hourglass in ##{name_of(channel_id)} now opens a case"
    end

    def drop_react
      channel_id = params[:channel_id].to_s.strip
      held = Fd::AppSetting.case_react_channels - [channel_id]
      keep(Fd::AppSetting.set_case_react_channels(held, by: current_account.user_id))
      redirect_to admin_settings_path, notice: "##{name_of(channel_id)} no longer opens cases"
    end

    private

    def keep(setting)
      audit(setting, "tuned") if setting
      setting
    end

    def known?(channel_id)
      Analytics::DimChannel.where(channel_id: channel_id).exists?
    end

    def name_of(channel_id)
      Analytics::DimChannel.find_by(channel_id: channel_id)&.name.presence || channel_id
    end

    def refuse(why = "that is not allowed")
      redirect_to admin_settings_path, alert: why
    end
  end
end
