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

ActiveRecord::Schema[8.1].define(version: 2026_08_30_160000) do
  create_schema "app"

  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "public.pg_trgm"

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

  create_table "app.cachet_profiles", primary_key: "user_id", id: :string, force: :cascade do |t|
    t.string "display_name"
    t.datetime "fetched_at", null: false
    t.string "image_url"
    t.string "pronouns"
    t.index ["display_name"], name: "index_cachet_profiles_on_display_name"
  end

  create_table "app.engine_setting", force: :cascade do |t|
    t.datetime "changed_at", default: -> { "now()" }, null: false
    t.string "changed_by", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.string "value", null: false
    t.index ["source", "name"], name: "index_engine_setting_on_source_and_name", unique: true
  end

  create_table "app.solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", null: false
    t.datetime "created_at", null: false
    t.binary "key", null: false
    t.bigint "key_hash", null: false
    t.binary "value", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
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
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying, 'claimed'::character varying, 'done'::character varying, 'failed'::character varying, 'cancelling'::character varying, 'cancelled'::character varying]::text[])", name: "sync_request_status_known"
  end

end
