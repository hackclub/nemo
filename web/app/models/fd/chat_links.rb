module Fd
  class ChatLinks
    def self.refs(*groups)
      groups.flatten.compact.flat_map { |row| refs_in(row) }.uniq
    end

    def self.refs_in(row)
      blocks = row.try(:blocks).presence || Slack::Mrkdwn.blocks(row.try(:body))
      Slack::RichText.link_urls({ "blocks" => blocks }).filter_map { |url| SlackLink.parse(url) }
    end
  end
end
