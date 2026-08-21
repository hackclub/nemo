module Fd
  class Marks
    OUT = %w[? >].freeze
    ANON = "~".freeze

    Read = Struct.new(:said, :to_reporter, :signed, keyword_init: true) do
      def to_reporter? = to_reporter
      def signed? = signed
      def mode = signed ? "signed" : "body"
    end

    def self.read(body, aimed: false)
      said = body.to_s.lstrip
      anon = said.start_with?(ANON) && (aimed || OUT.include?(said[1, 1]))
      said = said[1..].lstrip if anon

      out = OUT.include?(said[0, 1])
      said = said[1..].lstrip if out

      leaving = out || aimed
      Read.new(said: said, to_reporter: leaving, signed: leaving && !anon)
    end
  end
end
