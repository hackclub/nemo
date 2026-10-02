class OneActiveSyncRequest < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE app.sync_request SET status = 'cancelled', finished_at = now()
      WHERE status IN ('queued', 'claimed')
        AND id < (SELECT max(id) FROM app.sync_request WHERE status IN ('queued', 'claimed'))
    SQL

    execute <<~SQL
      CREATE UNIQUE INDEX one_active_sync_request
      ON app.sync_request ((status IN ('queued', 'claimed')))
      WHERE status IN ('queued', 'claimed')
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS app.one_active_sync_request"
  end
end
