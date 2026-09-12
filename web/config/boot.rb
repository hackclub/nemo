ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.

begin
  require "dotenv"
  env_file = File.expand_path("../../deploy/.env", __dir__)
  if File.exist?(env_file)
    Dotenv.parse(env_file).each do |name, value|
      ENV[name] = value if ENV[name].to_s.empty?
      ENV.delete(name) if ENV[name].to_s.empty?
    end
  end
rescue LoadError
  nil
end

require "bootsnap/setup" # Speed up boot time by caching expensive operations.
