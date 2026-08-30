require_relative "boot"

require "rails"

require "active_job/railtie"
require "active_model/railtie"
require "active_record/railtie"
require "action_cable/engine"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Web
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    ENCRYPTION_KEYS = %w[
      FD_ENCRYPTION_PRIMARY_KEY FD_ENCRYPTION_DETERMINISTIC_KEY FD_ENCRYPTION_SALT
    ].freeze
    ENCRYPTION_STANDIN = "mnemosyne-encryption-key-outside-production".freeze

    building = ENV["SECRET_KEY_BASE_DUMMY"].present?

    keys = ENCRYPTION_KEYS.map { |name| ENV[name].presence }
    if keys.any?(&:nil?)
      if Rails.env.production? && !building
        raise "#{ENCRYPTION_KEYS.join(", ")} must be set"
      end

      keys = keys.map { ENCRYPTION_STANDIN }
    end

    config.active_record.encryption.primary_key = keys[0]
    config.active_record.encryption.deterministic_key = keys[1]
    config.active_record.encryption.key_derivation_salt = keys[2]

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
