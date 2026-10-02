Rails.application.config.middleware.use OmniAuth::Builder do
  provider :openid_connect, {
    name: :hackclub,
    issuer: ENV.fetch("HCA_ISSUER", "https://auth.hackclub.com"),
    discovery: true,
    response_type: :code,
    scope: [:openid, :profile, :email, :name, :slack_id],
    client_options: {
      identifier: ENV["HCA_CLIENT_ID"],
      secret: ENV["HCA_CLIENT_SECRET"],
      redirect_uri: ENV["HCA_REDIRECT_URI"]
    }
  }
end

OmniAuth.config.allowed_request_methods = [:post]
OmniAuth.config.silence_get_warning = true
OmniAuth.config.failure_raise_out_environments = []
