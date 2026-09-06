require "net/http"

class WorkspaceLogo
  SOURCE = "https://shrimp-shuffler.a.hackclub.dev/api/current".freeze
  ALLOWED = %r{\Ahttps://[a-z0-9.-]*\.?(hackclub\.(com|dev)|hackclub-assets\.com)/}
  CACHE_KEY = "workspace_logo/url".freeze
  FOUND_FOR = 10.minutes
  MISSING_FOR = 2.minutes
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 3

  def self.url
    cached = Rails.cache.read(CACHE_KEY)
    return cached.presence if cached

    found = read
    Rails.cache.write(CACHE_KEY, found || "", expires_in: found ? FOUND_FOR : MISSING_FOR)
    found
  end

  def self.read
    uri = URI(SOURCE)
    said = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    return nil unless said.is_a?(Net::HTTPSuccess)

    candidate = said.body.to_s.strip.lines.first.to_s.strip
    candidate.match?(ALLOWED) ? candidate : nil
  rescue StandardError => e
    Rails.logger.warn("workspace logo unavailable: #{e.class}: #{e.message}")
    nil
  end
end
