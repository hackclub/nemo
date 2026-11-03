require "net/http"

class WorkspaceLogo
  SOURCE = "https://shrimp-shuffler.a.hackclub.dev/api/current".freeze
  HOSTS = %w[hackclub.com hackclub.dev hackclub-assets.com].freeze
  SUFFIXES = HOSTS.map { |host| ".#{host}" }.freeze
  CACHE_KEY = "workspace_logo/entry".freeze
  REFRESH_KEY = "workspace_logo/refresh".freeze
  IMAGE_TTL = 10.minutes
  KEEP_TTL = 7.days
  MISSING_TTL = 2.minutes
  REFRESH_LOCK_TTL = 1.minute
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5
  MAX_REDIRECTS = 3
  MAX_BYTES = 4.megabytes

  Image = Struct.new(:body, :type, keyword_init: true)

  def self.image
    cached = Rails.cache.read(CACHE_KEY)
    return refresh if cached.nil?

    WorkspaceLogoJob.perform_later if cached[:read_at].before?(IMAGE_TTL.ago) && claim_refresh
    cached[:image]
  end

  def self.refresh
    image = read
    if image
      Rails.cache.write(CACHE_KEY, { image: image, read_at: Time.current }, expires_in: KEEP_TTL)
    elsif !Rails.cache.exist?(CACHE_KEY)
      Rails.cache.write(CACHE_KEY, { image: nil, read_at: Time.current }, expires_in: MISSING_TTL)
    end
    image
  end

  def self.claim_refresh
    Rails.cache.write(REFRESH_KEY, true, expires_in: REFRESH_LOCK_TTL, unless_exist: true)
  end

  def self.read
    url = logo_url
    return nil if url.nil?

    fetch(url)
  rescue StandardError => e
    Rails.logger.warn("workspace logo unavailable: #{e.class}: #{e.message}")
    nil
  end

  def self.logo_url
    response = get(URI(SOURCE))
    return nil unless response.is_a?(Net::HTTPSuccess)

    found_url = response.body.to_s.strip.lines.first.to_s.strip
    uri = fetch_safely(found_url)
    uri && uri.to_s
  end

  def self.fetch(url)
    uri = fetch_safely(url)
    MAX_REDIRECTS.times do
      return nil if uri.nil?

      response = get(uri)
      return image_from(response) if response.is_a?(Net::HTTPSuccess)
      return nil unless response.is_a?(Net::HTTPRedirection)

      uri = fetch_safely(response["location"].to_s)
    end
    nil
  end

  def self.image_from(response)
    type = response["content-type"].to_s.split(";").first.to_s.strip
    return nil unless type.start_with?("image/")
    return nil if response.body.to_s.bytesize > MAX_BYTES || response.body.to_s.empty?

    Image.new(body: response.body, type: type)
  end

  def self.get(uri)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true,
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
  end

  def self.fetch_safely(url)
    uri = URI.parse(url.to_s)
    return nil unless uri.is_a?(URI::HTTPS)

    host = uri.host.to_s.downcase
    return nil unless HOSTS.include?(host) || SUFFIXES.any? { |suffix| host.end_with?(suffix) }

    uri
  rescue URI::InvalidURIError
    nil
  end
end
