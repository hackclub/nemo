class RemoveFirefighterFromStaff < ActiveRecord::Migration[8.1]
  def change
    remove_column :staff, :firefighter, :boolean, null: false, default: false
  end
end
