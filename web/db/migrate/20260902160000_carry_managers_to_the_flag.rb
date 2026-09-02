class CarryManagersToTheFlag < ActiveRecord::Migration[8.1]
  def up
    return if connection.select_value("SELECT to_regclass('fd.access_grants')").nil?

    execute <<~SQL
      UPDATE staff SET community_manager = true
      WHERE user_id IN (
        SELECT user_id FROM fd.access_grants
        WHERE role = 'community_manager'
          AND (revoked_at IS NULL OR revoked_by = 'migration')
      )
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
