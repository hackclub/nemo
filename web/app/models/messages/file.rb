module Messages
  class File
    METHOD = "files.read".freeze
    INLINE = %w[image/png image/jpeg image/gif image/webp].freeze
    FALLBACK = "application/octet-stream".freeze

    Result = Struct.new(:bytes, :kind, :name, :error, keyword_init: true)

    def self.listed(message)
      Array(message && message["files"]).select { |one| one["id"].present? }
    end

    def self.in(message, file_id)
      listed(message).find { |one| one["id"] == file_id }
    end

    def self.image?(one)
      INLINE.include?(one["mimetype"].to_s)
    end

    def self.bytes_of(one)
      body = Slack::ProxyClient.file(METHOD, { "url" => one["url_private"] })
      Result.new(bytes: body.bytes, kind: kind_for(one, body.kind), name: one["name"].presence)
    rescue Slack::ProxyClient::NotConfigured => e
      Rails.logger.error("slack file proxy is not configured: #{e.message}")
      Result.new(error: :not_configured)
    rescue Slack::ProxyClient::AuthError
      Result.new(error: :reauth)
    rescue Slack::ProxyClient::Error
      Result.new(error: :unavailable)
    end

    def self.kind_for(one, _said)
      image?(one) ? one["mimetype"] : FALLBACK
    end
  end
end
