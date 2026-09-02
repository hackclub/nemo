namespace :dev do
  PEOPLE = [
    { id: "UDEVMGR01", name: "Dev Manager", handle: "dev.manager",
      role: "community_manager" },
    { id: "UDEVFFR01", name: "Dev Firefighter", handle: "dev.firefighter",
      role: "firefighter" },
    { id: "UDEVFFR02", name: "Dev Firefighter (no acting)", handle: "dev.firefighter.cut",
      role: "firefighter", denied: %w[case.act case.resolve] },
    { id: "UDEVPRO01", name: "Dev Promethean", handle: "dev.promethean",
      role: "promethean", channels: 2 },
    { id: "UDEVGAR01", name: "Dev Gardener", handle: "dev.gardener",
      role: "gardener" },
    { id: "UDEVANA01", name: "Dev Analytics", handle: "dev.analytics",
      role: "analytics" },
    { id: "UDEVSCO01", name: "Dev Scoped", handle: "dev.scoped",
      added: %w[member.read engine.read] },
    { id: "UDEVMEM01", name: "Dev Member", handle: "dev.member" }
  ].freeze

  GARDENER_SET = 3

  desc "seed test accounts you can sign in as with /dev/be/:user_id"
  task people: :environment do
    abort "dev:people only runs in development" unless Rails.env.development?

    by = "dev:people"
    channels = Analytics::DimChannel.where(archived: false)
      .joins(Admin::ChannelsController::SPAN)
      .order(Arel.sql("s.total_members DESC NULLS LAST, dim_channel.name"))
      .limit(PEOPLE.sum { |one| one[:channels].to_i } + GARDENER_SET)
      .pluck(:channel_id, :name)

    remember_members(PEOPLE)
    pool = channels.dup

    PEOPLE.each do |one|
      settle_person(one, pool, by)
      puts "#{one[:id]}  #{one[:name].ljust(28)} #{said(one)}"
    end

    settle_gardener_set(pool.shift(GARDENER_SET), by)
    puts "\ngardener set: #{Channels::Audience::Grant.live.where(role: 'gardener').count} channels"
    puts "sign in with http://localhost:3000/dev/be/UDEVMGR01 (swap the id)"
  end

  desc "take back everything dev:people handed out"
  task unpeople: :environment do
    abort "dev:unpeople only runs in development" unless Rails.env.development?

    ids = PEOPLE.map { |one| one[:id] }
    Authz::Grant.live.where(user_id: ids).find_each { |row| row.take_back!(by: "dev:people") }
    Channels::Audience::Grant.live.where(user_id: ids).find_each do |row|
      row.update!(revoked_by: "dev:people", revoked_at: Time.current)
    end
    Channels::Audience::Grant.live.where(role: "gardener", granted_by: "dev:people")
      .find_each { |row| row.update!(revoked_by: "dev:people", revoked_at: Time.current) }
    puts "took back every dev grant, the #{ids.size} accounts still exist"
  end

  def settle_person(one, pool, by)
    Account.find_or_create_by!(user_id: one[:id])
    settle_role(one, by)
    Array(one[:added]).each do |key|
      Authz::Grant.give!(one[:id], kind: "capability", name: key, by: by, reason: "dev seed")
    end
    Array(one[:denied]).each do |key|
      Authz::Grant.give!(one[:id], kind: "capability", name: key, effect: "deny", by: by,
        reason: "dev seed")
    end
    name_channels(one, pool, by)
  end

  def settle_role(one, by)
    return if one[:role].blank?

    Authz::Grant.give!(one[:id], kind: "role", name: one[:role], by: by, reason: "dev seed")
  end

  def name_channels(one, pool, by)
    pool.shift(one[:channels].to_i).each do |channel_id, _name|
      next if Channels::Audience::Grant.live
        .where(user_id: one[:id], channel_id: channel_id).exists?

      Channels::Audience::Grant.create!(user_id: one[:id], channel_id: channel_id,
        granted_by: by, granted_at: Time.current, reason: "dev seed")
    end
  end

  def settle_gardener_set(channels, by)
    channels.each do |channel_id, _name|
      next if Channels::Audience::Grant.live
        .where(role: "gardener", channel_id: channel_id).exists?

      Channels::Audience::Grant.create!(role: "gardener", channel_id: channel_id,
        granted_by: by, granted_at: Time.current, reason: "dev seed")
    end
  end

  def said(one)
    parts = [one[:role] || "no role"]
    parts << "+#{one[:added].join(' +')}" if one[:added]
    parts << "-#{one[:denied].join(' -')}" if one[:denied]
    parts << "#{one[:channels]} named channels" if one[:channels]
    parts.join("  ")
  end

  MEMBER_INSERT = <<~SQL.freeze
    INSERT INTO fd.member (user_id, handle, display_name, is_bot, is_deleted, first_seen_at,
                           synced_at)
    VALUES ($1, $2, $3, false, false, now(), now())
    ON CONFLICT (user_id) DO UPDATE
      SET handle = EXCLUDED.handle, display_name = EXCLUDED.display_name
  SQL

  def remember_members(people)
    owner = owner_connection
    people.each do |one|
      owner.exec_query(MEMBER_INSERT, "dev:people", [one[:id], one[:handle], one[:name]])
    end
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError,
         ActiveRecord::ConnectionNotEstablished => e
    puts "could not write fd.member (#{e.class}), the pages will show @user_id instead"
  end

  def owner_connection
    unless defined?(DevSeedOwner)
      Object.const_set(:DevSeedOwner, Class.new(ActiveRecord::Base) { self.abstract_class = true })
    end
    DevSeedOwner.establish_connection(
      ActiveRecord::Base.connection_db_config.configuration_hash.merge(
        username: ENV.fetch("POSTGRES_USER"), password: ENV.fetch("POSTGRES_PASSWORD")
      )
    )
    DevSeedOwner.connection
  end
end
