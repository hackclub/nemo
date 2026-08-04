class CreateSyncRequest < ActiveRecord::Migration[8.1]
  STATUSES = %w[queued claimed done failed cancelling cancelled].freeze

  def change
    create_table :sync_request do |t|
      t.string :kind, null: false
      t.string :stage
      t.string :status, null: false, default: "queued"
      t.string :requested_by, null: false
      t.bigint :run_id
      t.datetime :claimed_at
      t.datetime :finished_at
      t.timestamps

      t.check_constraint "status IN (#{STATUSES.map { |s| "'#{s}'" }.join(', ')})",
        name: "sync_request_status_known"
      t.check_constraint "(kind = 'full' AND stage IS NULL) OR (kind = 'stage' AND stage IS NOT NULL)",
        name: "sync_request_stage_matches_kind"
    end

    add_index :sync_request, :status
    add_index :sync_request, :run_id

    reversible do |dir|
      dir.up { execute "GRANT SELECT, UPDATE ON app.sync_request TO pipeline_writer" }
    end
  end
end
