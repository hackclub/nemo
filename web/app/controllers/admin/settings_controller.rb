module Admin
  class SettingsController < BaseController
    def show
      @firehouse = Fd::AppSetting.firehouse_channel
      @react_channels = Fd::AppSetting.case_react_channels
      @named = Analytics::DimChannel
        .where(channel_id: ([@firehouse] + @react_channels).compact)
        .index_by(&:channel_id)
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
