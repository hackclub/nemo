class CreateEngineSetting < ActiveRecord::Migration[8.1]
  def change
    create_table :engine_setting do |t|
      t.string :source, null: false
      t.string :name, null: false
      t.string :value, null: false
      t.string :changed_by, null: false
      t.datetime :changed_at, null: false, default: -> { "now()" }
      t.timestamps
    end

    add_index :engine_setting, [:source, :name], unique: true

    reversible do |dir|
      dir.up do
        execute <<~SQL
          DO $$
          BEGIN
              IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pipeline_writer') THEN
                  GRANT SELECT ON app.engine_setting TO pipeline_writer;
              END IF;
          END
          $$
        SQL
      end
    end
  end
end
