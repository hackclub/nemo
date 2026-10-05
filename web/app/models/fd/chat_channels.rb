module Fd
  class ChatChannels
    def self.ids(*groups)
      groups.flatten.compact.flat_map { |row| ids_in(row) }.uniq
    end

    def self.ids_in(row)
      blocks = row.try(:blocks).presence || Slack::Mrkdwn.blocks(row.try(:body))
      Slack::RichText.channel_ids({ "blocks" => blocks })
    end
  end
end
