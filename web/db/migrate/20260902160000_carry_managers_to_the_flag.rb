class CarryManagersToTheFlag < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE staff SET community_manager = true
      WHERE user_id IN (
        SELECT user_id FROM fd.access_grants WHERE role = 'community_manager'
      )
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
