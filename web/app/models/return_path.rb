module ReturnPath
  LIMIT = 2000
  FORMAT = %r{\A/(?![/\\])[^\\[:cntrl:]]*\z}
  DENIED = %r{\A/(login|auth|logout|dev)(/|\?|\z)}

  def self.sanitize(value)
    return unless value.is_a?(String) && value.length <= LIMIT
    return unless value.match?(FORMAT)
    return if value.match?(DENIED)

    uri = URI.parse(value)
    uri.scheme || uri.host ? nil : value
  rescue URI::InvalidURIError
    nil
  end
end
