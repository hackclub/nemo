module Fd
  class AuditSearch
    Term = Struct.new(:kind, :value, :label, :hint, keyword_init: true) do
      def to_s = "#{kind}:#{value}"
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

    def self.parse(query, actor: nil)
      new(query, actor: actor)
    end

    def initialize(query, actor: nil)
      @query = query.to_s
      @actor = actor
    end

    attr_reader :actor

    def any? = terms.any?

    def terms
      @terms ||= tokens.filter_map { |token| term_for(token) }
    end

    def of(kind)
      terms.select { |term| term.kind == kind }.map(&:value)
    end

    def one(kind) = of(kind).first

    def text = of("text").join(" ")

    def text? = text.length >= 2

    def without(term)
      kept = terms.reject { |one| one.kind == term.kind && one.value == term.value }
      kept.map { |one| label_for(one) }.join(" ")
    end

    def label_for(term)
      return term.value if term.kind == "text"

      "#{term.kind}:#{term.value}"
    end

    def to_s = terms.map { |term| label_for(term) }.join(" ")

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
      parts = wanted.map { |query| query.include?("/") ? "ip << ?::inet" : "ip = ?::inet" }
      [parts.join(" OR "), *wanted]
    end

    QUOTED = /"([^"]*)"|(\S+)/

    def tokens
      @tokens ||= @query.scan(QUOTED).map { |quoted, bare| quoted || bare }.reject(&:blank?)
    end

    def term_for(token)
      found = PAIR.match(token)
      return typed(found[1].downcase, found[2]) if found && OPERATORS.key?(found[1].downcase)

      guessed(token)
    end

    def typed(operator, query)
      kind = OPERATORS.fetch(operator)
      value = query.strip.delete_prefix("@").delete_prefix("#")
      return nil if value.blank?

      case kind
      when "actor", "about" then person(kind, value)
      when "channel" then channel(value)
      when "source" then source(value)
      when "is" then doer(value)
      when "before", "after" then when_at(kind, value)
      when "domain" then addressed("domain", value)
      when "email" then addressed("email", value)
      else Term.new(kind: kind, value: value, label: "#{operator} #{value}")
      end
    end

    def guessed(token)
      query = token.strip
      return nil if query.blank?

      return person("about", query.delete_prefix("@")) if query.start_with?("@")
      return channel(query.delete_prefix("#")) if query.start_with?("#")
      return Term.new(kind: "ip", value: query, label: query) if address?(query)
      return person("about", query) if query.match?(MEMBER)
      return channel(query) if query.match?(CHANNEL)
      return Term.new(kind: "email", value: query, label: query) if query.match?(EMAIL)
      return when_at("after", query) if query.match?(DATE)

      Term.new(kind: "text", value: query, label: query)
    end

    def address?(query)
      query.match?(IPV4) || (query.include?(":") && query.match?(IPV6))
    end

    def person(kind, query)
      found = query.match?(MEMBER) ? query.upcase : by_handle(query)
      return Term.new(kind: "text", value: query, label: query) if found.nil?

      Term.new(kind: kind, value: found, label: "#{kind} #{query}", hint: found)
    end

    def by_handle(query)
      Member.where("lower(handle) = :query OR lower(display_name) = :query", query: query.downcase)
        .limit(1).pick(:user_id)
    end

    def channel(query)
      found = query.match?(CHANNEL) ? query.upcase : by_channel_name(query)
      return Term.new(kind: "text", value: query, label: query) if found.nil?

      Term.new(kind: "channel", value: found, label: "in #{query}", hint: found)
    end

    def by_channel_name(query)
      Analytics::DimChannel.where("lower(name) = ?", query.downcase).limit(1).pick(:channel_id)
    end

    def addressed(kind, query)
      held = query.downcase
      return Term.new(kind: "domain", value: held.split("@").last, label: "domain #{held.split('@').last}") if
        kind == "domain" && held.include?("@")
      return Term.new(kind: "domain", value: held, label: "domain #{held}") if
        kind == "email" && !held.include?("@") && held.match?(DOMAIN)

      Term.new(kind: kind, value: held, label: "#{kind} #{held}")
    end

    def doer(query)
      held = query.downcase
      held = "human" if held == "person"
      return nil unless DOERS.include?(held)

      Term.new(kind: "is", value: held, label: "by #{held == 'human' ? 'a person' : held}")
    end

    def source(query)
      held = query.downcase
      held = "fire_engine" if held == "engine"
      return nil unless SOURCES.include?(held)

      Term.new(kind: "source", value: held, label: "source #{query}")
    end

    def when_at(kind, query)
      at = Time.zone.parse(query)
      return nil if at.nil?

      Term.new(kind: kind, value: at.to_date.iso8601, label: "#{kind} #{at.to_date.iso8601}")
    rescue ArgumentError
      nil
    end
  end
end
