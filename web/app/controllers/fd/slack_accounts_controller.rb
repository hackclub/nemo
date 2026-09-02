module Fd
  class SlackAccountsController < BaseController
    skip_before_action :needs_the_engine
    permit "slack.link"

    STATE = :slack_link_state

    def create
      return stop("linking is not set up on this server") unless Slack::Oauth.configured?

      state = SecureRandom.urlsafe_base64(24)
      session[STATE] = state
      redirect_to Slack::Oauth.walk_to(redirect_uri: back_url, state: state),
        allow_other_host: true
    end

    def callback
      expected = session.delete(STATE)
      problem = objection(expected)
      return stop(problem) if problem

      granted = Slack::Oauth.exchange(code: params[:code], redirect_uri: back_url)
      problem = keep(granted)
      problem ? stop(problem) : done("your slack account is linked")
    rescue Slack::Oauth::Refused, Slack::Oauth::Unavailable, Slack::Oauth::NotConfigured => failure
      stop("slack did not hand over a token: #{failure.message}")
    end

    def destroy
      held = StaffSlack.held_by(current_staff.user_id)
      return stop("your slack account is not linked") if held.nil?

      Slack::Oauth.give_back(held.user_token)
      writing do
        held.give_back!(current_staff.user_id)
        audit(held, "unlinked", entity_id: 0, before: { "scopes" => held.scopes })
      end

      done("your slack account is unlinked, messages go out through nemo again")
    end

    private

    def objection(expected)
      return "linking was cancelled" if params[:error].present?
      return "that link attempt did not match this browser, try again" if
        expected.blank? || !ActiveSupport::SecurityUtils.secure_compare(
          params[:state].to_s, expected
        )
      return "slack did not send a code back" if params[:code].blank?

      nil
    end

    def keep(granted)
      authed = granted["authed_user"] || {}
      problem = wrong_with(authed, granted.dig("team", "id"))
      return problem if problem

      writing do
        row = StaffSlack.keep!(current_staff.user_id, token: authed["access_token"],
          team_id: granted.dig("team", "id").to_s, scopes: authed["scope"].to_s)
        audit(row, "linked", entity_id: 0,
          after: { "scopes" => row.scopes, "team_id" => row.team_id })
      end

      nil
    end

    def wrong_with(authed, team_id)
      return "slack granted an app token, not a token for you" if authed["access_token"].blank?
      return "that is not the account you are signed in as" if authed["id"] != current_staff.user_id
      unless authed["scope"].to_s.split(",").include?(StaffSlack::SCOPE)
        return "slack granted #{authed["scope"]}, which is not #{StaffSlack::SCOPE}"
      end
      if Slack::Oauth.workspace && team_id != Slack::Oauth.workspace
        return "that account is in a different workspace"
      end

      nil
    end

    def back_url
      fd_slack_account_callback_url
    end

    def stop(problem)
      redirect_to account_path, alert: problem
    end

    def done(said)
      redirect_to account_path, notice: said
    end
  end
end
