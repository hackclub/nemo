module Settings
  class ConsentsController < BaseController
    def update
      return refuse(turned_off) if api_off?

      key = params[:scope].to_s
      Api::Scope.fetch(key)
      app = app_asked
      return refuse("No such app") if params[:app_id].present? && app.nil?

      granted = params[:on] == "1"
      Api::Consent.set!(member_id, app&.id, key, granted, via: "dashboard")

      redirect_to settings_permissions_path, notice: notice_for(app, key, granted)
    rescue Api::Scope::UnknownError => e
      refuse(e.message)
    end

    private

    def app_asked
      return nil if params[:app_id].blank?

      found = Api::App.live.find_by(id: params[:app_id])
      found&.answering? ? found : nil
    end

    def notice_for(app, key, granted)
      named = Api::Scope.label(key).downcase
      who = app ? app.name : "Every app"
      granted ? "#{who} may ask about #{named}" : "#{who} may no longer ask"
    end

    def refuse(why)
      redirect_to settings_permissions_path, alert: why
    end
  end
end
