# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_04_183111) do
  create_schema "app"

  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "app.access_log", force: :cascade do |t|
    t.string "actor_id", null: false
    t.datetime "created_at", null: false
    t.string "field_class", null: false
    t.datetime "looked_at", null: false
    t.string "subject_user_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_access_log_on_actor_id"
    t.index ["subject_user_id"], name: "index_access_log_on_subject_user_id"
  end

  create_table "app.staff", primary_key: "user_id", id: :string, force: :cascade do |t|
    t.boolean "community_manager", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

end
