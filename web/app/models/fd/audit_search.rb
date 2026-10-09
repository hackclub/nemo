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

    KINDS = %w[actor about ip action category channel email domain source is show text
               before after last app].freeze

    OPERATORS = {
      "actor" => "actor", "by" => "actor", "who" => "actor",
      "about" => "about", "to" => "about", "subject" => "about",
      "ip" => "ip", "from" => "ip", "address" => "ip",
      "action" => "action", "did" => "action", "verb" => "action",
      "category" => "category",
      "show" => "show",
      "in" => "channel", "channel" => "channel",
      "email" => "email", "domain" => "domain",
      "source" => "source",
      "is" => "is",
      "before" => "before", "after" => "after", "since" => "after",
      "last" => "last", "within" => "last",
      "app" => "app"
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

    def since
      held = one("last")
      return nil if held.nil?

      count = held.to_i
      held.end_with?("h") ? count.hours.ago : (Date.current - (count - 1)).in_time_zone
    end

    def identity?
      return @identity if defined?(@identity)

      @identity = actor.present? && actor.may?("identity.read")
    end

    IDENTITY_KINDS = %w[ip email domain].freeze
    IDENTITY_TEXT = /\d{1,3}(?:\.\d{1,3}){3}|[^@\s":]+@[^@\s":]+\.[a-z]|\h{1,4}:\h{0,4}:/i

    def identity_terms?
      return true if IDENTITY_KINDS.any? { |kind| of(kind).any? }

      of("text").any? { |value| value.match?(IDENTITY_TEXT) }
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
      when "category" then category(value)
      when "show" then shown(value)
      when "is" then doer(value)
      when "before", "after" then when_at(kind, value)
      when "last" then recent(value)
      when "app" then app(value)
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

    SHOWN = { "high_volume" => "high_volume", "high-volume" => "high_volume", "busy" => "high_volume" }.freeze

    def shown(query)
      held = SHOWN[query.downcase]
      return nil if held.nil?

      Term.new(kind: "show", value: held, label: "high-volume actions")
    end

    def category(query)
      key = AuditCatalogue.category_for(query)
      return nil if key.nil?

      Term.new(kind: "category", value: key, label: AuditCatalogue.category_label(key))
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

    STAMP = /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/
    MINUTE = "%Y-%m-%dT%H:%M".freeze

    def when_at(kind, query)
      at = Time.zone.parse(query)
      return nil if at.nil?

      value = query.match?(STAMP) ? at.strftime(MINUTE) : at.to_date.iso8601
      Term.new(kind: kind, value: value, label: "#{kind} #{value.tr('T', ' ')}")
    rescue ArgumentError
      nil
    end

    APP = /\A[AB][A-Z0-9]{2,}\z/i

    def app(query)
      return nil unless query.match?(APP)

      Term.new(kind: "app", value: query.upcase, label: "app #{query.upcase}")
    end

    RECENT = /\A(\d{1,3})(h|d)\z/i
    UNITS = { "h" => "hour", "d" => "day" }.freeze

    def recent(query)
      found = RECENT.match(query.delete(" "))
      return nil if found.nil? || found[1].to_i.zero?

      count = found[1].to_i
      unit = UNITS.fetch(found[2].downcase)
      Term.new(kind: "last", value: "#{count}#{found[2].downcase}",
        label: "last #{count == 1 ? unit : "#{count} #{unit.pluralize}"}")
    end
  end
end
