module Fd
  class ApiSettingsController < BaseController
    skip_before_action :needs_the_engine
    permit "access.grant"

    MOST = 100_000

    def update
      key = params[:key].to_s
      return refuse("#{key} is not a setting") unless ::Api::Setting::DEFAULTS.key?(key)

      value = params[:value].to_i
      return refuse("a setting has to be a number above nought") unless value.positive?
      return refuse("#{value} is more than anybody needs") if value > MOST

      was = ::Api::Setting.value(key)
      writing do
        ::Api::Setting.set!(key, value, by: current_staff.user_id)
        ::Api::Event.record!("setting_changed", actor: current_staff.user_id,
          subject: key.tr("_", " "), detail: "#{was} to #{value}")
      end

      back_to "#{key.tr('_', ' ')} is now #{value}"
    end

    def rate
      token = ::Api::Token.find_by(id: params[:id])
      return refuse("no such token") if token.nil?

      value = params[:value].presence&.to_i
      return refuse("a rate has to be a number above nought") if value && !value.positive?

      was = token.rate
      writing do
        token.update!(rate_limit: value)
        ::Api::Event.record!("token_rate_set", actor: current_staff.user_id,
          subject: token.shown, detail: said_rate(token, was, value))
      end

      back_to "#{token.name} is now #{token.rate} a minute"
    end

    def destroy
      token = ::Api::Token.live.find_by(id: params[:id])
      return refuse("no live token with that id") if token.nil?

      writing do
        token.revoke!(by: current_staff.user_id)
        ::Api::Event.record!("token_revoked", actor: current_staff.user_id,
          subject: token.shown, detail: "#{token.name}, owned by #{token.owner_user_id}")
      end

      back_to "Revoked #{token.name}"
    end

    private

    def said_rate(token, was, value)
      return "#{token.name}, back to the shared #{token.rate}" if value.nil?

      "#{token.name}, #{was} to #{value}"
    end

    def back_to(said)
      redirect_to fd_settings_path(tab: "api"), notice: said
    end

    def refuse(said)
      redirect_to fd_settings_path(tab: "api"), alert: said
    end
  end
end
