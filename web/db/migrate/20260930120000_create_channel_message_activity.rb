class CreateChannelMessageActivity < ActiveRecord::Migration[8.1]
  def change
    create_table :channel_message_activity, id: false do |t|
      t.string :channel_id, null: false, primary_key: true
      t.string :set_by, null: false
      t.datetime :set_at, null: false, default: -> { "now()" }
    end
  end
end
