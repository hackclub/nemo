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

ActiveRecord::Schema[8.1].define(version: 2026_09_02_190000) do
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

  create_table "app.account", primary_key: "user_id", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "app.cachet_profiles", primary_key: "user_id", id: :string, force: :cascade do |t|
    t.string "display_name"
    t.datetime "fetched_at", null: false
    t.string "image_url"
    t.string "pronouns"
    t.index ["display_name"], name: "index_cachet_profiles_on_display_name"
  end

  create_table "app.capability", primary_key: "key", id: :text, force: :cascade do |t|
    t.text "area", null: false
    t.boolean "every_account", default: false, null: false
    t.text "label", null: false
    t.boolean "locked", default: false, null: false
    t.boolean "logged", default: false, null: false
    t.text "record_scope"
    t.check_constraint "record_scope IS NULL OR (record_scope = ANY (ARRAY['assigned'::text, 'author'::text, 'channel'::text]))", name: "capability_scope_known"
  end

  create_table "app.channel_audience", primary_key: "channel_id", id: :string, force: :cascade do |t|
    t.string "audience", null: false
    t.datetime "set_at", default: -> { "now()" }, null: false
    t.string "set_by", null: false
    t.index ["audience"], name: "channel_audience_open", where: "((audience)::text <> 'private'::text)"
    t.check_constraint "audience::text = ANY (ARRAY['private'::character varying, 'shared'::character varying, 'everyone'::character varying, 'granted'::character varying, 'public'::character varying]::text[])", name: "channel_audience_kind"
  end

  create_table "app.channel_backfill", force: :cascade do |t|
    t.string "cancelled_by"
    t.string "channel_id", null: false
    t.datetime "claimed_at"
    t.datetime "created_at", null: false
    t.integer "estimated_requests"
    t.datetime "finished_at"
    t.string "kind", default: "thread_replies", null: false
    t.string "last_error"
    t.datetime "last_progress_at"
    t.integer "priority", default: 100, null: false
    t.integer "replies_fetched", default: 0, null: false
    t.datetime "requested_at", default: -> { "now()" }, null: false
    t.string "requested_by", null: false
    t.string "state", default: "queued", null: false
    t.integer "threads_expected"
    t.integer "threads_fetched", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_channel_backfill_on_channel_id", unique: true
    t.index ["state", "priority", "requested_at"], name: "channel_backfill_ready_idx"
    t.check_constraint "state::text = ANY (ARRAY['queued'::character varying, 'draining'::character varying, 'paused'::character varying, 'complete'::character varying, 'cancelled'::character varying]::text[])", name: "channel_backfill_state_known"
  end

  create_table "app.channel_grants", force: :cascade do |t|
    t.string "channel_id", null: false
    t.datetime "granted_at", default: -> { "now()" }, null: false
    t.string "granted_by", null: false
    t.string "reason"
    t.datetime "revoked_at"
    t.string "revoked_by"
    t.text "role"
    t.string "user_id"
    t.index ["channel_id"], name: "channel_grants_by_channel", where: "(revoked_at IS NULL)"
    t.index ["role", "channel_id"], name: "channel_grants_one_live_role", unique: true, where: "((revoked_at IS NULL) AND (role IS NOT NULL))"
    t.index ["user_id", "channel_id"], name: "channel_grants_one_live", unique: true, where: "(revoked_at IS NULL)"
    t.check_constraint "(user_id IS NULL) <> (role IS NULL)", name: "channel_grants_one_subject"
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

  create_table "app.grant", id: :bigint, default: nil, force: :cascade do |t|
    t.text "effect", default: "allow", null: false
    t.timestamptz "granted_at", default: -> { "now()" }, null: false
    t.text "granted_by", null: false
    t.text "kind", null: false
    t.text "name", null: false
    t.text "reason"
    t.timestamptz "revoked_at"
    t.text "revoked_by"
    t.text "user_id", null: false
    t.index ["user_id", "kind", "name"], name: "grant_one_live", unique: true, where: "(revoked_at IS NULL)"
    t.index ["user_id"], name: "grant_live_by_user", where: "(revoked_at IS NULL)"
    t.check_constraint "(revoked_at IS NULL) = (revoked_by IS NULL)", name: "grant_revoked_together"
    t.check_constraint "effect = 'allow'::text OR kind = 'capability'::text", name: "grant_deny_is_a_capability"
    t.check_constraint "effect = ANY (ARRAY['allow'::text, 'deny'::text])", name: "grant_effect_known"
    t.check_constraint "kind = ANY (ARRAY['role'::text, 'capability'::text])", name: "grant_kind_known"
  end

  create_table "app.role", primary_key: "name", id: :text, force: :cascade do |t|
    t.boolean "everything", default: false, null: false
    t.boolean "grantable", default: true, null: false
    t.text "label", null: false
  end

  create_table "app.role_capability", primary_key: ["role", "capability"], force: :cascade do |t|
    t.text "capability", null: false
    t.text "role", null: false
  end

  create_table "app.role_override", primary_key: ["role", "capability"], force: :cascade do |t|
    t.boolean "allowed", null: false
    t.text "capability", null: false
    t.timestamptz "changed_at", default: -> { "now()" }, null: false
    t.text "changed_by", null: false
    t.text "role", null: false
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
    t.index "(((status)::text = ANY ((ARRAY['queued'::character varying, 'claimed'::character varying])::text[])))", name: "one_active_sync_request", unique: true, where: "((status)::text = ANY ((ARRAY['queued'::character varying, 'claimed'::character varying])::text[]))"
    t.index ["run_id"], name: "index_sync_request_on_run_id"
    t.index ["status"], name: "index_sync_request_on_status"
    t.check_constraint "kind::text = 'full'::text AND stage IS NULL OR kind::text = 'stage'::text AND stage IS NOT NULL", name: "sync_request_stage_matches_kind"
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying, 'claimed'::character varying, 'done'::character varying, 'failed'::character varying, 'cancelling'::character varying, 'cancelled'::character varying]::text[])", name: "sync_request_status_known"
  end

  add_foreign_key "app.role_capability", "app.capability", column: "capability", primary_key: "key", name: "role_capability_capability_fkey", on_delete: :cascade
  add_foreign_key "app.role_capability", "app.role", column: "role", primary_key: "name", name: "role_capability_role_fkey", on_delete: :cascade
  add_foreign_key "app.role_override", "app.capability", column: "capability", primary_key: "key", name: "role_override_capability_fkey", on_delete: :cascade
  add_foreign_key "app.role_override", "app.role", column: "role", primary_key: "name", name: "role_override_role_fkey", on_delete: :cascade

end
