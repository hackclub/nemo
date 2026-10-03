module Fd
  class Marks
    OUT = %w[? >].freeze
    ANON = "~".freeze

    Read = Struct.new(:body, :to_reporter, :signed, keyword_init: true) do
      def to_reporter? = to_reporter
      def signed? = signed
      def mode = signed ? "signed" : "body"
    end

    def self.read(body, aimed: false)
      text = body.to_s.lstrip
      anon = text.start_with?(ANON) && (aimed || OUT.include?(text[1, 1]))
      text = text[1..].lstrip if anon

      out = OUT.include?(text[0, 1])
      text = text[1..].lstrip if out

      leaving = out || aimed
      Read.new(body: text, to_reporter: leaving, signed: leaving && !anon)
    end
  end
end
