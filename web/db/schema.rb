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

ActiveRecord::Schema[8.1].define(version: 2026_08_04_193454) do
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

  create_table "app.sync_request", force: :cascade do |t|
    t.datetime "claimed_at"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "kind", null: false
    t.string "requested_by", null: false
    t.bigint "run_id"
    t.string "stage"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id"], name: "index_sync_request_on_run_id"
    t.index ["status"], name: "index_sync_request_on_status"
    t.check_constraint "kind::text = 'full'::text AND stage IS NULL OR kind::text = 'stage'::text AND stage IS NOT NULL", name: "sync_request_stage_matches_kind"
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying::text, 'claimed'::character varying::text, 'done'::character varying::text, 'failed'::character varying::text, 'cancelling'::character varying::text, 'cancelled'::character varying::text])", name: "sync_request_status_known"
  end

end
