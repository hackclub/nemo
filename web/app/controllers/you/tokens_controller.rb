module You
  class TokensController < BaseController
    def create
      return refuse(turned_off) if Fd::Flag.off?(:public_api)
      return refuse("name what the token is for") if params[:name].to_s.strip.empty?

      token, @secret = Api::Token.mint!(member_id, params[:name], lasting: params[:lasting])
      Api::Event.record!("token_minted", actor: member_id, subject: token.shown,
        detail: [token.name, Api::Token::LIFE_WORDS.fetch(Api::Token.life_for(params[:lasting]))]
          .join(", "))

      @token = token
      show_again
    rescue Api::Token::TooMany
      refuse("you already hold #{Api::Setting.value('tokens_per_owner')} tokens")
    end

    def destroy
      token = Api::Token.live.find_by(id: params[:id], owner_user_id: member_id)
      return refuse("that token is not yours") if token.nil?

      token.revoke!(by: member_id)
      Api::Event.record!("token_revoked", actor: member_id, subject: token.shown,
        detail: token.name)

      redirect_to you_api_path(tab: "tokens"), notice: "Revoked #{token.name}"
    end

    private

    def turned_off
      "#{Fd::Flag.label(:public_api).downcase} is turned off"
    end

    def refuse(said)
      redirect_to you_api_path(tab: "tokens"), alert: said
    end

    def show_again
      @tab = "tokens"
      @consents = Api::Consent.states_for(member_id)
      @tokens = Api::Token.for_owner(member_id)
      @rooms = SlackScan.channels(member_id)
      render "you/api/show"
    end
  end
end
