module Fd
  class AuditSearch
    Term = Struct.new(:kind, :said, :label, :hint, keyword_init: true) do
      def to_s = "#{kind}:#{said}"
    end

    MEMBER = /\A[UW][A-Z0-9]{2,}\z/i
    CHANNEL = /\A[CGD][A-Z0-9]{2,}\z/i
    IPV4 = %r{\A\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?\z}
    IPV6 = %r{\A[0-9a-f]{0,4}(:[0-9a-f]{0,4}){2,7}(/\d{1,3})?\z}i
    EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
    DOMAIN = /\A[a-z0-9-]+(\.[a-z0-9-]+)+\z/i
    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    KINDS = %w[actor about ip action channel email domain source is text
               before after].freeze

    OPERATORS = {
      "actor" => "actor", "by" => "actor", "who" => "actor",
      "about" => "about", "to" => "about", "subject" => "about",
      "ip" => "ip", "from" => "ip", "address" => "ip",
      "action" => "action", "did" => "action", "verb" => "action",
      "in" => "channel", "channel" => "channel",
      "email" => "email", "domain" => "domain",
      "source" => "source",
      "is" => "is",
      "before" => "before", "after" => "after", "since" => "after"
    }.freeze

    SOURCES = %w[engine slack read fire_engine].freeze
    DOERS = %w[nemo human nobody].freeze

    PAIR = /\A([a-z_]+):(.+)\z/i

    def self.parse(said, actor: nil)
      new(said, actor: actor)
    end

    def initialize(said, actor: nil)
      @said = said.to_s
      @actor = actor
    end

    attr_reader :actor

    def any? = terms.any?

    def terms
      @terms ||= tokens.filter_map { |token| term_for(token) }
    end

    def of(kind)
      terms.select { |term| term.kind == kind }.map(&:said)
    end

    def one(kind) = of(kind).first

    def text = of("text").join(" ")

    def text? = text.length >= 2

    def without(term)
      kept = terms.reject { |one| one.kind == term.kind && one.said == term.said }
      kept.map { |one| said_for(one) }.join(" ")
    end

    def said_for(term)
      return term.said if term.kind == "text"

      "#{term.kind}:#{term.said}"
    end

    def to_s = terms.map { |term| said_for(term) }.join(" ")

    def identity?
      return @identity if defined?(@identity)

      @identity = actor.present? && actor.may?("identity.read")
    end

    def people_for_email
      return @people_for_email if defined?(@people_for_email)

      wanted = of("email").map(&:downcase)
      domains = of("domain").map(&:downcase)
      @people_for_email =
        if !identity? || (wanted.empty? && domains.empty?)
          []
        else
          MemberIdentity.kept.where(held_email(wanted, domains)).pluck(:user_id)
        end
    end

    def people_for_ip
      return @people_for_ip if defined?(@people_for_ip)

      wanted = of("ip")
      @people_for_ip =
        wanted.empty? ? [] : LoginEvent.addressed.where(held_ip(wanted)).distinct.pluck(:user_id)
    end

    private

    def held_email(emails, domains)
      parts = []
      binds = {}
      if emails.any?
        parts << "lower(email) IN (:emails)"
        binds[:emails] = emails
      end
      if domains.any?
        parts << "lower(split_part(email, '@', 2)) IN (:domains)"
        binds[:domains] = domains
      end
      [parts.join(" OR "), binds]
    end

    def held_ip(wanted)
      parts = wanted.map { |said| said.include?("/") ? "ip << ?::inet" : "ip = ?::inet" }
      [parts.join(" OR "), *wanted]
    end

    QUOTED = /"([^"]*)"|(\S+)/

    def tokens
      @tokens ||= @said.scan(QUOTED).map { |quoted, bare| quoted || bare }.reject(&:blank?)
    end

    def term_for(token)
      found = PAIR.match(token)
      return typed(found[1].downcase, found[2]) if found && OPERATORS.key?(found[1].downcase)

      guessed(token)
    end

    def typed(operator, said)
      kind = OPERATORS.fetch(operator)
      value = said.strip.delete_prefix("@").delete_prefix("#")
      return nil if value.blank?

      case kind
      when "actor", "about" then person(kind, value)
      when "channel" then channel(value)
      when "source" then source(value)
      when "is" then doer(value)
      when "before", "after" then when_at(kind, value)
      when "domain" then addressed("domain", value)
      when "email" then addressed("email", value)
      else Term.new(kind: kind, said: value, label: "#{operator} #{value}")
      end
    end

    def guessed(token)
      said = token.strip
      return nil if said.blank?

      return person("about", said.delete_prefix("@")) if said.start_with?("@")
      return channel(said.delete_prefix("#")) if said.start_with?("#")
      return Term.new(kind: "ip", said: said, label: said) if address?(said)
      return person("about", said) if said.match?(MEMBER)
      return channel(said) if said.match?(CHANNEL)
      return Term.new(kind: "email", said: said, label: said) if said.match?(EMAIL)
      return when_at("after", said) if said.match?(DATE)

      Term.new(kind: "text", said: said, label: said)
    end

    def address?(said)
      said.match?(IPV4) || (said.include?(":") && said.match?(IPV6))
    end

    def person(kind, said)
      found = said.match?(MEMBER) ? said.upcase : by_handle(said)
      return Term.new(kind: "text", said: said, label: said) if found.nil?

      Term.new(kind: kind, said: found, label: "#{kind} #{said}", hint: found)
    end

    def by_handle(said)
      Member.where("lower(handle) = :said OR lower(display_name) = :said", said: said.downcase)
        .limit(1).pick(:user_id)
    end

    def channel(said)
      found = said.match?(CHANNEL) ? said.upcase : by_channel_name(said)
      return Term.new(kind: "text", said: said, label: said) if found.nil?

      Term.new(kind: "channel", said: found, label: "in #{said}", hint: found)
    end

    def by_channel_name(said)
      Analytics::DimChannel.where("lower(name) = ?", said.downcase).limit(1).pick(:channel_id)
    end

    def addressed(kind, said)
      held = said.downcase
      return Term.new(kind: "domain", said: held.split("@").last, label: "domain #{held.split('@').last}") if
        kind == "domain" && held.include?("@")
      return Term.new(kind: "domain", said: held, label: "domain #{held}") if
        kind == "email" && !held.include?("@") && held.match?(DOMAIN)

      Term.new(kind: kind, said: held, label: "#{kind} #{held}")
    end

    def doer(said)
      held = said.downcase
      held = "human" if held == "person"
      return nil unless DOERS.include?(held)

      Term.new(kind: "is", said: held, label: "by #{held == 'human' ? 'a person' : held}")
    end

    def source(said)
      held = said.downcase
      held = "fire_engine" if held == "engine"
      return nil unless SOURCES.include?(held)

      Term.new(kind: "source", said: held, label: "source #{said}")
    end

    def when_at(kind, said)
      at = Time.zone.parse(said)
      return nil if at.nil?

      Term.new(kind: kind, said: at.to_date.iso8601, label: "#{kind} #{at.to_date.iso8601}")
    rescue ArgumentError
      nil
    end
  end
end
