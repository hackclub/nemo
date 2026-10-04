module Slack
  class Mrkdwn
    FENCE = /```\n?(.*?)```/m
    QUOTE = /\A(?:>|&gt;)\s?/
    ENTITIES = { "&amp;" => "&", "&lt;" => "<", "&gt;" => ">" }.freeze
    ENTITY = /&(?:amp|lt|gt);/

    TOKEN = %r{
      (?<code>`(?<code_in>[^`\n]+)`)
      | (?<user><@(?<user_id>[UW][A-Z0-9]{2,})(?:\|[^>]*)?>)
      | (?<channel><\#(?<channel_id>C[A-Z0-9]{2,})(?:\|(?<channel_name>[^>]*))?>)
      | (?<link><(?<url>https?://[^|>\s]+)(?:\|(?<label>[^>]*))?>)
      | (?<bare>https?://[^\s<>]+)
      | (?<emoji>:(?<emoji_name>[a-z0-9][a-z0-9_+'\-]*):)
      | (?<bold>\*(?<bold_in>[^*\n]*\S)\*)
      | (?<italic>_(?<italic_in>[^_\n]*\S)_)
      | (?<strike>~(?<strike_in>[^~\n]*\S)~)
    }x

    def self.blocks(text)
      new(text).blocks
    end

    def initialize(text)
      @text = text.to_s
    end

    def blocks
      parts = segments.filter_map { |one| segment(one) }
      parts.any? ? [{ "type" => "rich_text", "elements" => parts }] : []
    end

    private

    def segment(one)
      case one[:kind]
      when :pre
        { "type" => "rich_text_preformatted",
          "elements" => [{ "type" => "text", "text" => unescape(one[:text]) }] }
      when :quote
        { "type" => "rich_text_quote", "elements" => inline(one[:text]) }
      else
        { "type" => "rich_text_section", "elements" => inline(one[:text]) }
      end
    end

    def segments
      found = []
      at = 0
      @text.scan(FENCE) do
        held = Regexp.last_match
        found.concat(plain_segments(@text[at...held.begin(0)]))
        found << { kind: :pre, text: held[1].sub(/\n\z/, "") }
        at = held.end(0)
      end
      found.concat(plain_segments(@text[at..].to_s))
      found
    end

    def plain_segments(text)
      return [] if text.to_s.strip.empty?

      text.split("\n", -1)
        .chunk_while { |one, next_one| quoted?(one) == quoted?(next_one) }
        .filter_map { |run| run_segment(run) }
    end

    def run_segment(run)
      quoting = quoted?(run.first)
      body = run.map { |line| quoting ? line.sub(QUOTE, "") : line }.join("\n")
      return nil if body.strip.empty?

      { kind: quoting ? :quote : :section, text: body }
    end

    def quoted?(line)
      line.match?(QUOTE)
    end

    def inline(text, style = {})
      out = []
      at = 0
      while (found = TOKEN.match(text, at))
        before = text[at...found.begin(0)]
        out << text_part(before, style) unless before.empty?
        out.concat(parts_for(found, style))
        at = found.end(0)
      end
      rest = text[at..].to_s
      out << text_part(rest, style) unless rest.empty?
      out
    end

    def parts_for(found, style)
      return [text_part(found[:code_in], style.merge("code" => true))] if found[:code]
      return [{ "type" => "user", "user_id" => found[:user_id] }] if found[:user]
      return [{ "type" => "channel", "channel_id" => found[:channel_id] }] if found[:channel]
      return [link_part(found[:url], found[:label])] if found[:link]
      return [link_part(found[:bare], nil)] if found[:bare]
      return [{ "type" => "emoji", "name" => found[:emoji_name] }] if found[:emoji]
      return inline(found[:bold_in], style.merge("bold" => true)) if found[:bold]
      return inline(found[:italic_in], style.merge("italic" => true)) if found[:italic]

      inline(found[:strike_in], style.merge("strike" => true))
    end

    def text_part(text, style)
      made = { "type" => "text", "text" => unescape(text) }
      made["style"] = style if style.any?
      made
    end

    def link_part(url, label)
      made = { "type" => "link", "url" => unescape(url.to_s) }
      shown = unescape(label.to_s)
      made["text"] = shown if shown.present? && shown != made["url"]
      made
    end

    def unescape(text)
      text.to_s.gsub(ENTITY) { |one| ENTITIES[one] }
    end
  end
end
