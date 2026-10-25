module Slack
  class RichText
    include ActionView::Helpers::TagHelper
    include ActionView::Helpers::OutputSafetyHelper

    BROADCASTS = { "here" => "@here", "channel" => "@channel", "everyone" => "@everyone" }.freeze
    LISTS = { "bullet" => "ul", "ordered" => "ol" }.freeze
    DEEPEST = 5
    OPENABLE = ["http://", "https://"].freeze

    def self.for(message, names: {}, channels: {}, emoji: {}, usergroups: {},
                 user_chip: nil, channel_chip: nil, link_chip: nil)
      new(names, channels, emoji, usergroups: usergroups, user_chip: user_chip,
        channel_chip: channel_chip, link_chip: link_chip).to_text(message || {})
    end

    def self.emoji_names(message)
      names = []
      walk = lambda do |node|
        case node
        when Hash
          names << node["name"] if node["type"] == "emoji" && node["name"].present?
          node["elements"]&.each { |child| walk.call(child) }
        when Array then node.each { |child| walk.call(child) }
        end
      end
      walk.call((message || {})["blocks"])
      names.uniq
    end

    def self.channel_ids(message)
      ids = []
      walk = lambda do |node|
        case node
        when Hash
          ids << node["channel_id"] if node["type"] == "channel" && node["channel_id"].present?
          node["elements"]&.each { |child| walk.call(child) }
        when Array then node.each { |child| walk.call(child) }
        end
      end
      walk.call((message || {})["blocks"])
      ids.uniq
    end

    def self.link_urls(message)
      urls = []
      walk = lambda do |node|
        case node
        when Hash
          urls << node["url"] if node["type"] == "link"
          urls << mention_url(node) if node["type"] == "message_mention"
          node["elements"]&.each { |child| walk.call(child) }
        when Array then node.each { |child| walk.call(child) }
        end
      end
      walk.call((message || {})["blocks"])
      urls.compact_blank.uniq
    end

    def self.mention_url(node)
      return node["url"] if node["url"].present?
      return nil if node["channel_id"].blank? || node["message_ts"].blank?

      url = Fd::SlackLink.url_for(node["channel_id"], node["message_ts"])
      thread_ts = node["thread_ts"]
      thread_ts.present? && thread_ts != node["message_ts"] ? "#{url}?thread_ts=#{thread_ts}" : url
    end

    def self.user_ids(message)
      ids = []
      walk = lambda do |node|
        case node
        when Hash
          ids << node["user_id"] if node["type"] == "user" && node["user_id"].present?
          node["elements"]&.each { |child| walk.call(child) }
        when Array then node.each { |child| walk.call(child) }
        end
      end
      walk.call((message || {})["blocks"])
      ids.uniq
    end

    def initialize(names = {}, channels = {}, emoji = {}, usergroups: {}, user_chip: nil,
                   channel_chip: nil, link_chip: nil)
      @names = names
      @channels = channels
      @emoji = emoji
      @usergroups = usergroups
      @user_chip = user_chip
      @channel_chip = channel_chip
      @link_chip = link_chip
    end

    def to_text(message)
      rendered = blocks(message["blocks"])
      return rendered if rendered.present?

      lines(message["text"].to_s)
    end

    def blocks(raw_blocks)
      safe_join(Array(raw_blocks).filter_map { |node| block(node) })
    end

    private

    attr_reader :names, :channels, :emoji, :usergroups

    def block(node)
      case node["type"]
      when "rich_text" then safe_join(Array(node["elements"]).filter_map { |part| rich(part) })
      when "section" then paragraph(lines(node.dig("text", "text").to_s))
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
      safe_join(Array(elements).map { |node| styled(node, element(node)) })
    end

    def flat(elements)
      safe_join(Array(elements).map { |node| plain_text(node) })
    end

    def element(node)
      case node["type"]
      when "text" then lines(node["text"].to_s)
      when "link" then linked(node)
      when "emoji" then emoji_for(node)
      when "user" then user_mention(node["user_id"])
      when "usergroup" then chip(usergroup_ref(node["usergroup_id"]))
      when "channel" then channel_mention(node["channel_id"])
      when "broadcast" then chip(BROADCASTS.fetch(node["range"], "@#{node['range']}"))
      when "message_mention" then message_mention(node)
      when "date" then dated(node)
      when "color" then tag.span(node["value"].to_s, class: "rt-colour")
      else lines(node["text"].to_s)
      end
    end

    def plain_text(node)
      text = node["type"] == "text" ? node["text"].to_s : node.values_at("text", "name", "url").compact.first.to_s
      ERB::Util.html_escape(text)
    end

    def styled(node, text)
      style = node["style"]
      return text unless style.is_a?(Hash) && text.present?

      text = tag.code(text, class: "richtext-code") if style["code"]
      text = tag.strong(text) if style["bold"]
      text = tag.em(text) if style["italic"]
      text = tag.s(text) if style["strike"]
      text
    end

    def linked(node)
      url = node["url"].to_s
      label = node["text"].presence || url
      return ERB::Util.html_escape(label) unless OPENABLE.any? { |scheme| url.start_with?(scheme) }

      link_to_url(label, url)
    end

    def message_mention(node)
      url = self.class.mention_url(node)
      return linked(node.merge("text" => node["text"].presence || "a message")) if url.nil?

      linked(node.merge("url" => url))
    end

    def link_to_url(label, url)
      return @link_chip.call(url, label) if @link_chip

      tag.a(ERB::Util.html_escape(label), href: url, class: "richtext-link",
        target: "_blank", rel: "noopener")
    end

    def dated(node)
      at = Time.zone.at(node["timestamp"].to_i)
      tag.time(at.strftime("%-d %b %Y"), datetime: at.iso8601, class: "rt-date")
    rescue StandardError
      ERB::Util.html_escape(node["timestamp"].to_s)
    end

    def emoji_for(node)
      name = node["name"]
      text = ":#{name}:"
      url = emoji[name].presence
      if url
        return tag.img(src: url, class: "richtext-emoji-img", alt: text, loading: "lazy",
          width: 20, height: 20)
      end

      character = UnicodeEmoji.for(name, unicode: node["unicode"], skin_tone: node["skin_tone"])
      return tag.span(character, class: "richtext-emoji-char", title: text) if character

      tag.span(text, class: "richtext-emoji")
    end

    def usergroup_ref(usergroup_id)
      handle = usergroups[usergroup_id].presence || usergroup_id
      "@#{handle.to_s.delete_prefix('@')}"
    end

    def user_mention(user_id)
      return chip(user_ref(user_id)) if @user_chip.nil?

      @user_chip.call(user_id)
    end

    def channel_mention(channel_id)
      return chip(channel_ref(channel_id)) if @channel_chip.nil?

      @channel_chip.call(channel_id)
    end

    def chip(text)
      tag.span(text, class: "richtext-mention")
    end

    def user_ref(user_id)
      label = names[user_id].presence || user_id
      label.to_s.start_with?("@") ? label : "@#{label}"
    end

    def channel_ref(channel_id)
      label = channels[channel_id].presence || channel_id
      label.to_s.start_with?("#") ? label : "##{label}"
    end

    def lines(text)
      return "".html_safe if text.empty?

      safe_join(text.split("\n", -1).map { |line| ERB::Util.html_escape(line) }, tag.br)
    end
  end
end
