# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

AVATAR_HOSTS = [
  "https://avatars.slack-edge.com", "https://*.dunkirk.sh", "https://secure.gravatar.com"
].freeze

AUTH_ORIGIN = begin
  issuer = URI.parse(ENV.fetch("HCA_ISSUER", "https://auth.hackclub.com"))
  port = issuer.port unless issuer.port == issuer.default_port
  ["#{issuer.scheme}://#{issuer.host}", port].compact.join(":")
rescue URI::InvalidURIError
  "https://auth.hackclub.com"
end

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src     :self
    policy.font_src        :self
    policy.img_src         :self, :data, *AVATAR_HOSTS
    policy.object_src      :none
    policy.script_src      :self
    policy.style_src       :self, :unsafe_inline
    host = ENV["APP_HOST"].presence
    sockets = host ? ["ws://#{host}", "wss://#{host}"] : ["ws://localhost:*"]
    policy.connect_src     :self, *sockets
    policy.base_uri        :self
    policy.form_action     :self, AUTH_ORIGIN
    policy.frame_ancestors :none
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
