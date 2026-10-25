module Fd
  class Marks
    OUT = %w[? >].freeze
    ANON = "~".freeze
    RESOLVE = "resolve".freeze
    INTERNAL_RESOLVE = /\A!\s*resolve\z/i

    Read = Struct.new(:body, :to_reporter, :signed, keyword_init: true) do
      def to_reporter? = to_reporter
      def signed? = signed
      def mode = signed ? "signed" : "body"
    end

    def self.read(body, to_reporter: false)
      text = body.to_s.lstrip
      anon = text.start_with?(ANON) && (to_reporter || OUT.include?(text[1, 1]))
      text = text[1..].lstrip if anon

      out = OUT.include?(text[0, 1])
      text = text[1..].lstrip if out

      outbound = out || to_reporter
      Read.new(body: text, to_reporter: outbound, signed: outbound && !anon)
    end

    def self.resolve_command?(body, to_reporter: false)
      text = body.to_s.strip
      return true if text.match?(INTERNAL_RESOLVE)

      parsed = read(text, to_reporter: to_reporter)
      parsed.to_reporter? && parsed.body.casecmp?(RESOLVE)
    end
  end
end
