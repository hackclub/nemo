class CreateCommunityGrants < ActiveRecord::Migration[8.1]
  FAMILIES = %w[read ops].freeze
  AUDIENCES = %w[private shared everyone].freeze

  def change
    create_table :community_grants do |t|
      t.string :user_id, null: false
      t.string :family, null: false
      t.string :role, null: false
      t.string :granted_by, null: false
      t.datetime :granted_at, null: false, default: -> { "now()" }
      t.string :revoked_by
      t.datetime :revoked_at
      t.string :reason
    end

    add_index :community_grants, [:user_id, :family], unique: true,
      where: "revoked_at IS NULL", name: "community_grants_one_live"
    add_index :community_grants, :user_id, where: "revoked_at IS NULL",
      name: "community_grants_live"
    add_check_constraint :community_grants, "family IN (#{quoted(FAMILIES)})",
      name: "community_grants_family"

    create_table :channel_grants do |t|
      t.string :user_id, null: false
      t.string :channel_id, null: false
      t.string :granted_by, null: false
      t.datetime :granted_at, null: false, default: -> { "now()" }
      t.string :revoked_by
      t.datetime :revoked_at
      t.string :reason
    end

    add_index :channel_grants, [:user_id, :channel_id], unique: true,
      where: "revoked_at IS NULL", name: "channel_grants_one_live"
    add_index :channel_grants, :channel_id, where: "revoked_at IS NULL",
      name: "channel_grants_by_channel"

    create_table :channel_audience, id: false do |t|
      t.string :channel_id, null: false, primary_key: true
      t.string :audience, null: false
      t.string :set_by, null: false
      t.datetime :set_at, null: false, default: -> { "now()" }
    end

    add_check_constraint :channel_audience, "audience IN (#{quoted(AUDIENCES)})",
      name: "channel_audience_kind"
    add_index :channel_audience, :audience, where: "audience <> 'private'",
      name: "channel_audience_open"
  end

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(", ")
  end
end
