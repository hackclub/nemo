class CreateStaff < ActiveRecord::Migration[8.1]
  def change
    create_table :staff, id: :string, primary_key: :user_id do |t|
      t.boolean :community_manager, null: false, default: false
      t.boolean :firefighter, null: false, default: false
      t.timestamps
    end
  end
end
