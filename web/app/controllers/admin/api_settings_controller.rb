module Admin
  class ApiSettingsController < BaseController
    WINDOW = 30.days
    MOST = 100_000

    def show
      @tokens = ::Api::Token.includes(:app).order(revoked_at: :asc, created_at: :desc).to_a
      @apps = ::Api::App.live.count
      @answering = ::Api::App.answering.count
      @asks = ::Api::RequestLog.where(at: WINDOW.ago..).group(:token_id).count
      @opted_in = ::Api::Consent.where(state: ::Api::Consent::GRANTED).count
      @checks = ::Api::RequestLog.where(at: WINDOW.ago..).count
      @withheld = ::Api::RequestLog.where(at: WINDOW.ago.., outcome: "withheld").count
      @channels = ::Api::RequestLog.where(at: WINDOW.ago..).distinct.count(:channel_id)
      @synced = ::Api::ChannelSweep.maximum(:synced_at)
      @dials = ::Api::Setting::DEFAULTS.keys.index_with { |key| ::Api::Setting.value(key) }
      @last_dial = ::Api::Setting.order(changed_at: :desc).first
      @names = Fd::Names.for(@tokens.map(&:owner_user_id))
    end

    def update
      key = params[:key].to_s
      return refuse("#{key} is not a setting") unless ::Api::Setting::DEFAULTS.key?(key)

      value = params[:value].to_i
      return refuse("A setting must be a number greater than zero") unless value.positive?
      return refuse("#{value} exceeds the maximum") if value > MOST

      was = ::Api::Setting.value(key)
      writing do
        ::Api::Setting.set!(key, value, by: current_account.user_id)
        ::Api::Event.record!("setting_changed", actor: current_account.user_id,
          subject: key.tr("_", " "), detail: "#{was} to #{value}")
      end

      back_to "#{key.tr('_', ' ')} is now #{value}"
    end

    def rate
      token = ::Api::Token.find_by(id: params[:id])
      return refuse("No such key") if token.nil?

      value = params[:value].presence&.to_i
      return refuse("A rate must be a number greater than zero") if value && !value.positive?

      was = token.rate
      writing do
        token.update!(rate_limit: value)
        ::Api::Event.record!("token_rate_set", actor: current_account.user_id,
          subject: token.shown, detail: rate_notice(token, was, value))
      end

      back_to "#{token.name} is now #{token.rate} a minute"
    end

    def destroy
      token = ::Api::Token.live.find_by(id: params[:id])
      return refuse("No live key with that id") if token.nil?

      writing do
        token.revoke!(by: current_account.user_id)
        ::Api::Event.record!("token_revoked", actor: current_account.user_id,
          subject: token.shown, detail: "#{token.name}, owned by #{token.owner_user_id}")
      end

      back_to "Revoked #{token.name}"
    end

    private

    def writing
      ActiveRecord::Base.transaction { yield }
    end

    def rate_notice(token, was, value)
      return "#{token.name}, back to the shared #{token.rate}" if value.nil?

      "#{token.name}, #{was} to #{value}"
    end

    def back_to(message)
      redirect_to admin_api_path, notice: message
    end

    def refuse(message)
      redirect_to admin_api_path, alert: message
    end
  end
end
