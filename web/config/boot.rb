ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.

begin
  require "dotenv"
  env_file = File.expand_path("../../infra/.env", __dir__)
  Dotenv.load(env_file) if File.exist?(env_file)
rescue LoadError
  nil
end

require "bootsnap/setup" # Speed up boot time by caching expensive operations.
