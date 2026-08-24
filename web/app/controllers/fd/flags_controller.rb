module Fd
  class FlagsController < BaseController
    permit "app.flip"

    def update
      key = params[:key].to_s
      on = params[:on] == "1"

      writing do
        row = Flag.set!(key, on, by: current_staff.user_id)
        audit(row, on ? "turned_on" : "turned_off",
          after: { "flag" => key, "on" => on })
      end

      redirect_to fd_settings_path(tab: "sections"), notice: flipped_note(key, on)
    rescue Flag::Unknown => e
      redirect_to fd_settings_path(tab: "sections"), alert: e.message
    end

    private

    def flipped_note(key, on)
      said = Flag.label(key).downcase
      on ? "#{said} is back" : "#{said} is turned off, and nothing was deleted"
    end
  end
end
