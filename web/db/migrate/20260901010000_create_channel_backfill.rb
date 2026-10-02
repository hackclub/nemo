class CreateChannelBackfill < ActiveRecord::Migration[8.1]
  STATES = %w[queued draining paused complete cancelled].freeze

  def change
    create_table :channel_backfill do |t|
      t.string :channel_id, null: false
      t.string :kind, null: false, default: "thread_replies"
      t.string :state, null: false, default: "queued"
      t.integer :priority, null: false, default: 100
      t.string :requested_by, null: false
      t.datetime :requested_at, null: false, default: -> { "now()" }
      t.integer :estimated_requests
      t.integer :threads_expected
      t.integer :threads_fetched, null: false, default: 0
      t.integer :replies_fetched, null: false, default: 0
      t.datetime :claimed_at
      t.datetime :last_progress_at
      t.datetime :finished_at
      t.string :cancelled_by
      t.string :last_error
      t.timestamps

      t.check_constraint "state IN (#{STATES.map { |s| "'#{s}'" }.join(', ')})",
        name: "channel_backfill_state_known"
    end

    add_index :channel_backfill, :channel_id, unique: true
    add_index :channel_backfill, [:state, :priority, :requested_at],
      name: "channel_backfill_ready_idx"

    reversible do |dir|
      dir.up do
        execute <<~SQL
          DO $$
          BEGIN
              IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
                  GRANT SELECT, UPDATE ON app.channel_backfill TO pipeline_writer;
              END IF;
          END $$;
        SQL
      end
    end
  end
end
