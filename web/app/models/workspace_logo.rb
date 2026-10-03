require "net/http"

class WorkspaceLogo
  SOURCE = "https://shrimp-shuffler.a.hackclub.dev/api/current".freeze
  HOSTS = %w[hackclub.com hackclub.dev hackclub-assets.com].freeze
  SUFFIXES = HOSTS.map { |host| ".#{host}" }.freeze
  CACHE_KEY = "workspace_logo/image".freeze
  FOUND_FOR = 10.minutes
  MISSING_FOR = 2.minutes
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5
  HOPS = 3
  BIGGEST = 4.megabytes

  Image = Struct.new(:body, :type, keyword_init: true)

  def self.image
    cached = Rails.cache.read(CACHE_KEY)
    return cached.presence && cached if cached

    found = read
    Rails.cache.write(CACHE_KEY, found || "", expires_in: found ? FOUND_FOR : MISSING_FOR)
    found
  end

  def self.read
    url = pointed_at
    return nil if url.nil?

    fetch(url)
  rescue StandardError => e
    Rails.logger.warn("workspace logo unavailable: #{e.class}: #{e.message}")
    nil
  end

  def self.pointed_at
    answer = get(URI(SOURCE))
    return nil unless answer.is_a?(Net::HTTPSuccess)

    where = answer.body.to_s.strip.lines.first.to_s.strip
    uri = fetch_safely(where)
    uri && uri.to_s
  end

  def self.fetch(url)
    uri = fetch_safely(url)
    HOPS.times do
      return nil if uri.nil?

      answer = get(uri)
      return picture(answer) if answer.is_a?(Net::HTTPSuccess)
      return nil unless answer.is_a?(Net::HTTPRedirection)

      uri = fetch_safely(answer["location"].to_s)
    end
    nil
  end

  def self.picture(answer)
    type = answer["content-type"].to_s.split(";").first.to_s.strip
    return nil unless type.start_with?("image/")
    return nil if answer.body.to_s.bytesize > BIGGEST || answer.body.to_s.empty?

    Image.new(body: answer.body, type: type)
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
    return nil unless HOSTS.include?(host) || SUFFIXES.any? { |one| host.end_with?(one) }

    uri
  rescue URI::InvalidURIError
    nil
  end
end
