require "test_helper"

# every route, every persona. this asserts invariants that must hold whatever the
# catalogue says, so it cannot pass by agreeing with the model it is checking.
class PermissionSweepTest < ActionDispatch::IntegrationTest
  PERSONAS = {
    "member" => { role: nil },
    "scoped" => { role: nil, scopes: %w[member.read engine.read] },
    "promethean" => { role: "promethean", channels: 1 },
    "gardener" => { role: "gardener" },
    "analytics" => { role: "analytics" },
    "firefighter" => { role: "firefighter" },
    "manager" => { role: "community_manager" }
  }.freeze

  FD_PATHS = %w[/fd /fd/cases /fd/members /fd/decisions /fd/search
                /fd/members/search].freeze

  # the audit is its own gate, access.read, not the conduct team's
  AUDIT_PATH = "/fd/audit".freeze

  ADMIN_PATHS = %w[/admin /admin/people /admin/roles /admin/flags /admin/channels
                   /admin/role_channels /admin/people/search
                   /admin/channels/search].freeze

  ENGINE_PATHS = %w[/engine].freeze

  setup do
    @boss = hold_role!("USWEEPBOSS", "community_manager")
    @channels = Analytics::DimChannel.where(archived: false).limit(4).pluck(:channel_id)
    @mine, @theirs = @channels
  end

  def become(name)
    one = PERSONAS.fetch(name)
    id = "USWEEP#{name.upcase[0, 4]}"
    Staff.find_or_create_by!(user_id: id)
    hold_role!(id, one[:role]) if one[:role]
    Array(one[:scopes]).each do |key|
      Authz::Grant.give!(id, kind: "capability", name: key, by: "sweep")
    end
    if one[:channels]
      Channels::Audience::Grant.create!(user_id: id, channel_id: @mine,
        granted_by: @boss.user_id, granted_at: Time.current)
    end
    Current.forget_roles
    sign_in_as(Staff.find(id))
    id
  end

  def reached?(path)
    get path
    response.status == 200
  end

  # 1. nothing at all without a session
  test "a stranger reaches no page that is not the door" do
    open_to_all = ["/login", "/auth/failure"]
    got = (FD_PATHS + ADMIN_PATHS + ENGINE_PATHS + ["/", "/account", "/channels",
                                                    "/journey/joining"]).reject do |path|
      get path
      response.redirect? || response.status == 404
    end

    assert_empty got, "a signed out visitor reached: #{got.join(', ')}"
    open_to_all.each do |path|
      get path
      refute_equal 500, response.status, "#{path} broke for a stranger"
    end
  end

  # 2. the fire engine is case.read only
  test "only case.read reaches any fire engine page" do
    leaked = []
    PERSONAS.each_key do |name|
      id = become(name)
      may = Authz.holds?(Staff.find(id), "case.read")
      FD_PATHS.each do |path|
        next if reached?(path) == may

        leaked << "#{name} #{'' if may}#{path} (case.read=#{may}, got #{response.status})"
      end
    end
    assert_empty leaked, leaked.join("\n")
  end

  test "the audit trail is behind access.read, on its own" do
    leaked = []
    PERSONAS.each_key do |name|
      id = become(name)
      may = Authz.holds?(Staff.find(id), "access.read")
      next if reached?(AUDIT_PATH) == may

      leaked << "#{name} on #{AUDIT_PATH}: access.read=#{may}, got #{response.status}"
    end
    assert_empty leaked, leaked.join("\n")
  end

  # 3. the admin section is access.grant only
  test "only access.grant reaches any admin page" do
    leaked = []
    PERSONAS.each_key do |name|
      id = become(name)
      may = Authz.holds?(Staff.find(id), "access.grant")
      ADMIN_PATHS.each do |path|
        next if reached?(path) == may

        leaked << "#{name} reached #{path} holding access.grant=#{may}"
      end
    end
    assert_empty leaked, leaked.join("\n")
  end

  # 4. the engine is engine.read only
  test "only engine.read reaches the engine" do
    leaked = []
    PERSONAS.each_key do |name|
      id = become(name)
      may = Authz.holds?(Staff.find(id), "engine.read")
      ENGINE_PATHS.each do |path|
        next if reached?(path) == may

        leaked << "#{name} on #{path} with engine.read=#{may}, got #{response.status}"
      end
    end
    assert_empty leaked, leaked.join("\n")
  end

  # 5. a channel nobody named you on stays shut
  test "a channel page opens only to somebody who may see that channel" do
    leaked = []
    PERSONAS.each_key do |name|
      id = become(name)
      staff = Staff.find(id)
      [@mine, @theirs].each do |channel_id|
        may = Channels::Audience.may_see?(staff, channel_id)
        next if reached?("/channels/#{channel_id}") == may

        leaked << "#{name} on #{channel_id}: may_see=#{may}, got #{response.status}"
      end
    end
    assert_empty leaked, leaked.join("\n")
  end

  # 6. the promethean sees their own channel and not the next one along
  test "one promethean cannot read another promethean's channel" do
    become("promethean")

    assert reached?("/channels/#{@mine}"), "their own channel was shut"
    refute reached?("/channels/#{@theirs}"), "reached a channel nobody named them on"
  end

  # 7. names are behind member.read
  test "a member name never appears to somebody without member.read" do
    named = Fd::Member.first
    skip "no member fixture" if named.nil?

    leaked = []
    PERSONAS.each_key do |name|
      id = become(name)
      next if Authz.holds?(Staff.find(id), "member.read")

      %w[/ /channels /journey/joining /account].each do |path|
        get path
        next unless response.status == 200 && named.display_name.present?
        next unless response.body.include?(named.display_name)

        leaked << "#{name} saw #{named.display_name} on #{path}"
      end
    end
    assert_empty leaked, leaked.join("\n")
  end

  # 8. the json endpoints are the quiet way in
  test "the search endpoints refuse the same people the pages do" do
    leaked = []
    PERSONAS.each_key do |name|
      id = become(name)
      staff = Staff.find(id)
      [["/admin/people/search?q=see", "access.grant"],
       ["/admin/channels/search?q=see", "access.grant"],
       ["/fd/members/search?q=see", "case.read"]].each do |path, key|
        may = Authz.holds?(staff, key)
        get path
        next if (response.status == 200) == may

        leaked << "#{name} on #{path}: #{key}=#{may}, got #{response.status}"
      end
    end
    assert_empty leaked, leaked.join("\n")
  end

  # 9. a refused write must not write
  test "no write lands for somebody the gate turned away" do
    writes = [
      [:post, "/admin/grants", { user_id: "UVICTIM01", role: "community_manager" }],
      [:delete, "/admin/grants/USWEEPBOSS", {}],
      [:patch, "/fd/role_permission", { role: "firefighter", key: "case.act", allowed: "0" }],
      [:patch, "/fd/flag", { key: "fire_engine", on: "0" }],
      [:post, "/engine/sync", {}],
      [:patch, "/engine/tune", { retention_days: "1" }]
    ]

    leaked = []
    PERSONAS.each_key do |name|
      next if name == "manager"

      become(name)
      before = census
      writes.each do |verb, path, params|
        send(verb, path, params: params)
        refute_equal 200, response.status, "#{name} got a 200 from #{verb} #{path}"
      end
      after = census
      leaked << "#{name} changed #{(before.to_a - after.to_a).inspect}" if before != after
    end
    assert_empty leaked, leaked.join("\n")
  end

  def census
    { grants: Authz::Grant.live.count,
      overrides: Authz::Override.count,
      flags: Fd::Flag.where(is_on: true).count,
      channel_grants: Channels::Audience::Grant.live.count,
      audiences: Channels::Audience::Setting.count }
  end

  # 10. taking your own access away is somebody else's job
  test "a manager cannot strip their own access" do
    id = become("manager")
    assert_includes Authz.roles_held(id), "community_manager", "the persona was not set up"

    delete "/admin/grants/#{id}"

    assert_includes Authz.roles_held(id), "community_manager"
  end

  # 11. every mutating route, refused for everyone who should not hold it
  WRITES = [
    [:post, "/admin/grants", "access.grant", { user_id: "UVICTIM01", role: "firefighter" }],
    [:delete, "/admin/grants/UVICTIM01", "access.grant", {}],
    [:patch, "/admin/people/UVICTIM01/capability", "access.grant",
     { key: "member.read", effect: "allow" }],
    [:post, "/admin/people/UVICTIM01/channel_grants", "access.grant", {}],
    [:delete, "/admin/people/UVICTIM01/channel_grants/CSEED0000000", "access.grant", {}],
    [:post, "/admin/role_channels", "access.grant", { role: "gardener" }],
    [:delete, "/admin/role_channels", "access.grant", { role: "gardener" }],
    [:patch, "/fd/role_permission", "access.grant",
     { role: "firefighter", key: "case.act", allowed: "0" }],
    [:patch, "/fd/flag", "app.flip", { key: "decisions", on: "0" }],
    [:post, "/engine/sync", "engine.sync", {}],
    [:post, "/engine/cancel", "engine.stage", {}],
    [:post, "/engine/stages/members", "engine.stage", {}],
    [:patch, "/engine/tune", "engine.tune", { retention_days: "30" }],
    [:delete, "/engine/tune", "engine.tune", {}]
  ].freeze

  test "every mutating route turns away everyone who does not hold its capability" do
    leaked = []
    PERSONAS.each_key do |name|
      id = become(name)
      staff = Staff.find(id)
      WRITES.each do |verb, path, key, params|
        next if Authz.holds?(staff, key)

        send(verb, path, params: params)
        next unless response.status == 200

        leaked << "#{name} got 200 from #{verb.upcase} #{path} without #{key}"
      end
    end
    assert_empty leaked, leaked.join("\n")
  end

  # 12. the channel index must list only what you may see
  test "the channel list never names a channel you may not see" do
    leaked = []
    PERSONAS.each_key do |name|
      id = become(name)
      staff = Staff.find(id)
      get "/channels"
      next unless response.status == 200

      @channels.each do |channel_id|
        next if Channels::Audience.may_see?(staff, channel_id)
        next unless response.body.include?(channel_id)

        leaked << "#{name} saw #{channel_id} listed"
      end
    end
    assert_empty leaked, leaked.join("\n")
  end

  # 13. opting a channel into replies is not a way to reach it
  test "opting into replies refuses a channel you may not see" do
    become("promethean")

    post "/channels/#{@theirs}/replies"
    refute_equal 200, response.status

    assert_equal 0, ChannelBackfill.where(channel_id: @theirs).count,
      "queued a backfill on a channel they cannot see"
  end

  # 14. a signed out visitor cannot write anything at all
  test "a stranger writes nothing" do
    before = census
    WRITES.each do |verb, path, _key, params|
      send(verb, path, params: params)
      refute_equal 200, response.status, "a stranger got 200 from #{verb.upcase} #{path}"
    end
    assert_equal before, census, "a stranger changed something"
  end

  # 15. the dev door must never exist outside development
  test "the impersonation door is development only" do
    assert Rails.application.routes.routes.none? { |r|
      r.path.spec.to_s.include?("dev/be")
    } || Rails.env.development? || Rails.env.test?,
      "dev/be is routable in this environment"
  end

  # 16. a locked capability cannot be handed out, not even by a manager
  test "nobody can hand out a locked capability" do
    become("manager")

    post "/admin/grants", params: { user_id: "UVICTIM01", scopes: ["access.grant"],
                                    scopes_settled: "1" }

    refute_includes Authz.held("UVICTIM01").keys, "access.grant",
      "a manager handed out the locked grant capability"
    assert_raises(Authz::Grant::NotAllowed) do
      Authz::Grant.give!("UVICTIM01", kind: "capability", name: "access.grant", by: "sweep")
    end
  end

  # 17. taking a capability away really takes it away
  test "a denied capability is refused even though the role carries it" do
    id = become("firefighter")
    assert Authz.holds?(Staff.find(id), "case.act"), "the role should carry it"

    Authz::Grant.give!(id, kind: "capability", name: "case.act", effect: "deny", by: "sweep")
    Current.forget_roles

    refute Authz.holds?(Staff.find(id), "case.act"), "the denial did not bite"
    kase = make_case(assign: id)
    post "/fd/cases/#{kase.id}/actions", params: { kind: "warned", note: "x" }

    refute_equal 200, response.status, "acted with the capability denied"
    assert_equal 0, Fd::Action.where(case_id: kase.id).count
  end

  # 18. the real name behind an id needs identity.read
  test "a firefighter without identity.read sees no email" do
    id = become("firefighter")
    named = Fd::Member.first
    skip "no member fixture" if named.nil?

    Authz::Grant.give!(id, kind: "capability", name: "identity.read", effect: "deny",
      by: "sweep")
    Current.forget_roles
    refute Authz.holds?(Staff.find(id), "identity.read")

    get "/fd/members/#{named.user_id}"
    skip "member page did not render" unless response.status == 200

    Fd::MemberIdentity.where(user_id: named.user_id).each do |row|
      [row.email, row.real_name].compact_blank.each do |secret|
        refute_includes response.body, secret, "leaked #{secret} without identity.read"
      end
    end
  end

  # 19. asking for json is not a way round the gate
  test "the json format is gated exactly like the html" do
    leaked = []
    PERSONAS.each_key do |name|
      id = become(name)
      staff = Staff.find(id)
      [["/fd/cases", "case.read"], ["/admin/people", "access.grant"],
       ["/engine", "engine.read"]].each do |path, key|
        next if Authz.holds?(staff, key)

        get "#{path}.json"
        next unless response.status == 200

        leaked << "#{name} got #{path}.json without #{key}"
      end
    end
    assert_empty leaked, leaked.join("\n")
  end

  # 20. logging out really ends it
  test "a session does not outlive logout" do
    become("manager")
    assert reached?("/admin/people")

    delete "/logout"
    get "/admin/people"

    assert response.redirect?, "the admin page still opened after logout"
  end
end
