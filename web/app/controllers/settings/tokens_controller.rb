module Settings
  class TokensController < KeysController
    def create
      return refuse(turned_off) if api_off?

      app = owned_app(params[:app_id])
      return refuse("That app is not yours") if app.nil?
      return refuse("Say what the key is for") if params[:name].to_s.strip.empty?

      token, @secret = Api::Token.mint!(app, params[:name], lasting: params[:lasting])
      Api::Event.record!("token_minted", actor: member_id, subject: token.shown,
        detail: [app.name, token.name,
          Api::Token::LIFE_WORDS.fetch(Api::Token.life_for(params[:lasting]))].join(", "))

      @token = token
      load_keys
      render "settings/keys/show"
    rescue Api::Token::NotApprovedError
      refuse("That app has no approved scope yet")
    rescue Api::Token::TooManyError
      refuse("that app already holds #{Api::Setting.value('tokens_per_owner')} keys")
    end

    def rotate
      return refuse(turned_off) if api_off?

      token = own_token
      return refuse("That key is not yours") if token.nil?

      @secret = token.rotate!(by: member_id)
      @token = token
      load_keys
      render "settings/keys/show"
    end

    def destroy
      token = own_token
      return refuse("That key is not yours") if token.nil?

      token.revoke!(by: member_id)
      Api::Event.record!("token_revoked", actor: member_id, subject: token.shown,
        detail: token.name)

      redirect_to settings_keys_path, notice: "Revoked #{token.name}"
    end

    private

    def owned_app(id)
      Api::App.live.find_by(id: id, owner_user_id: member_id)
    end

    def own_token
      Api::Token.live.find_by(id: params[:id], owner_user_id: member_id)
    end

    def refuse(message)
      redirect_to settings_keys_path, alert: message
    end
  end
end
