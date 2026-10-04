module Fd
  class ChatEmoji
    def self.for(*groups)
      Slack::Emoji.for(groups.flatten.compact.flat_map { |row| names_in(row) })
    end

    def self.names_in(row)
      blocks = row.try(:blocks).presence || Slack::Mrkdwn.blocks(row.try(:body))
      Slack::RichText.emoji_names({ "blocks" => blocks })
    end
  end
end
