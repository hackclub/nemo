class CreateCachetProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :cachet_profiles, id: false do |t|
      t.string :user_id, null: false, primary_key: true
      t.string :display_name
      t.string :image_url
      t.string :pronouns
      t.datetime :fetched_at, null: false
    end

    add_index :cachet_profiles, :display_name
  end
end
