module Slack
  class RichText
    include ActionView::Helpers::TagHelper
    include ActionView::Helpers::OutputSafetyHelper

    BROADCASTS = { "here" => "@here", "channel" => "@channel", "everyone" => "@everyone" }.freeze
    LISTS = { "bullet" => "ul", "ordered" => "ol" }.freeze
    DEEPEST = 5
    OPENABLE = ["http://", "https://"].freeze

    def self.for(message, names: {}, channels: {}, emoji: {},
                 user_chip: nil, channel_chip: nil, link_chip: nil)
      new(names, channels, emoji, user_chip: user_chip, channel_chip: channel_chip,
        link_chip: link_chip).to_text(message || {})
    end

    def self.emoji_names(message)
      found = []
      walk = lambda do |node|
        case node
        when Hash
          found << node["name"] if node["type"] == "emoji" && node["name"].present?
          node["elements"]&.each { |one| walk.call(one) }
        when Array then node.each { |one| walk.call(one) }
        end
      end
      walk.call((message || {})["blocks"])
      found.uniq
    end

    def initialize(names = {}, channels = {}, emoji = {}, user_chip: nil, channel_chip: nil,
                   link_chip: nil)
      @names = names
      @channels = channels
      @emoji = emoji
      @user_chip = user_chip
      @channel_chip = channel_chip
      @link_chip = link_chip
    end

    def to_text(message)
      shown = blocks(message["blocks"])
      return shown if shown.present?

      lines(message["text"].to_s)
    end

    def blocks(given)
      safe_join(Array(given).filter_map { |one| block(one) })
    end

    private

    attr_reader :names, :channels, :emoji

    def block(one)
      case one["type"]
      when "rich_text" then safe_join(Array(one["elements"]).filter_map { |part| rich(part) })
      when "section" then paragraph(lines(one.dig("text", "text").to_s))
      when "divider" then tag.hr(class: "richtext-rule")
      end
    end

    def rich(part)
      case part["type"]
      when "rich_text_section" then paragraph(inline(part["elements"]))
      when "rich_text_list" then listed(part)
      when "rich_text_quote" then tag.blockquote(inline(part["elements"]), class: "richtext-quote")
      when "rich_text_preformatted" then tag.pre(tag.code(flat(part["elements"])), class: "richtext-pre")
      end
    end

    def paragraph(text)
      text.present? ? tag.p(text, class: "richtext-text") : nil
    end

    def listed(part)
      kind = LISTS.fetch(part["style"], "ul")
      rows = safe_join(Array(part["elements"]).map { |row| tag.li(inline(row["elements"])) })
      depth = part["indent"].to_i.clamp(0, DEEPEST)
      start = part["offset"].to_i + 1

      tag.send(kind, rows, class: "richtext-list richtext-indent-#{depth}",
        **(kind == "ol" && start > 1 ? { start: start } : {}))
    end

    def inline(elements)
      safe_join(Array(elements).map { |one| styled(one, element(one)) })
    end

    def flat(elements)
      safe_join(Array(elements).map { |one| plain_text(one) })
    end

    def element(one)
      case one["type"]
      when "text" then lines(one["text"].to_s)
      when "link" then linked(one)
      when "emoji" then emoji_for(one["name"])
      when "user" then shown_user(one["user_id"])
      when "usergroup" then chip("@#{one['usergroup_id']}", one["usergroup_id"])
      when "channel" then shown_channel(one["channel_id"])
      when "broadcast" then chip(BROADCASTS.fetch(one["range"], "@#{one['range']}"), one["range"])
      when "message_mention" then linked(one.merge("text" => one["text"].presence || "a message"))
      when "date" then dated(one)
      when "color" then tag.span(one["value"].to_s, class: "rt-colour")
      else lines(one["text"].to_s)
      end
    end

    def plain_text(one)
      text = one["type"] == "text" ? one["text"].to_s : one.values_at("text", "name", "url").compact.first.to_s
      ERB::Util.html_escape(text)
    end

    def styled(one, text)
      style = one["style"]
      return text unless style.is_a?(Hash) && text.present?

      text = tag.code(text, class: "richtext-code") if style["code"]
      text = tag.strong(text) if style["bold"]
      text = tag.em(text) if style["italic"]
      text = tag.s(text) if style["strike"]
      text
    end

    def linked(one)
      url = one["url"].to_s
      label = one["text"].presence || url
      return ERB::Util.html_escape(label) unless OPENABLE.any? { |scheme| url.start_with?(scheme) }

      link_to_url(label, url)
    end

    def link_to_url(label, url)
      return @link_chip.call(url, label) if @link_chip

      tag.a(ERB::Util.html_escape(label), href: url, class: "richtext-link",
        target: "_blank", rel: "noopener")
    end

    def dated(one)
      at = Time.zone.at(one["timestamp"].to_i)
      tag.time(at.strftime("%-d %b %Y"), datetime: at.iso8601, class: "rt-date")
    rescue StandardError
      ERB::Util.html_escape(one["timestamp"].to_s)
    end

    def emoji_for(name)
      text = ":#{name}:"
      url = emoji[name].presence
      return tag.span(text, class: "richtext-emoji", title: name) if url.nil?

      tag.img(src: url, class: "richtext-emoji-img", alt: text, title: text, loading: "lazy",
        width: 20, height: 20)
    end

    def shown_user(user_id)
      return chip(named(user_id), user_id) if @user_chip.nil?

      @user_chip.call(user_id)
    end

    def shown_channel(channel_id)
      return chip(channel_ref(channel_id), channel_id) if @channel_chip.nil?

      @channel_chip.call(channel_id)
    end

    def chip(text, title)
      tag.span(text, class: "richtext-mention", title: title)
    end

    def named(user_id)
      shown = names[user_id].presence || user_id
      shown.to_s.start_with?("@") ? shown : "@#{shown}"
    end

    def channel_ref(channel_id)
      shown = channels[channel_id].presence || channel_id
      shown.to_s.start_with?("#") ? shown : "##{shown}"
    end

    def lines(text)
      return "".html_safe if text.empty?

      safe_join(text.split("\n", -1).map { |line| ERB::Util.html_escape(line) }, tag.br)
    end
  end
end
