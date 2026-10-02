module You
  class ConsentsController < BaseController
    def update
      return redirect_to(you_api_path, alert: turned_off) if Fd::Flag.off?(:public_api)

      key = params[:capability].to_s
      Api::Scope.fetch(key)
      granted = params[:on] == "1"
      Api::Consent.set!(member_id, key, granted, via: "dashboard")

      redirect_to you_api_path, notice: said(key, granted)
    rescue Api::Scope::Unknown => e
      redirect_to you_api_path, alert: e.message
    end

    private

    def turned_off
      "#{Fd::Flag.label(:public_api).downcase} is turned off"
    end

    def said(key, granted)
      named = Api::Scope.label(key).downcase
      granted ? "Opted in to #{named}" : "Opted out of #{named}"
    end
  end
end
