module Fd
  class JoinModeController < BaseController
    permit "channel.guard"

    SAID = {
      AppSetting::ON => "nemo joins every public channel",
      AppSetting::GUARDED => "nemo joins guarded channels only",
      AppSetting::OFF => "nemo joins nothing new"
    }.freeze

    def update
      how = params[:mode].to_s.strip.downcase
      unless AppSetting::MODES.include?(how)
        return redirect_to fd_channels_path, alert: "that is not a join mode"
      end
      return redirect_to fd_channels_path if how == AppSetting.join_mode

      writing do
        setting = AppSetting.set_join_mode(how, by: current_account.user_id)
        audit(setting, "tuned")
      end

      redirect_to fd_channels_path, notice: SAID.fetch(how)
    end
  end
end
