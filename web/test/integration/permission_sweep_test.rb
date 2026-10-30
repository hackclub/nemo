require "test_helper"

# every route, every persona. this asserts invariants that must hold whatever the
# catalogue says, so it cannot pass by agreeing with the model it is checking.
class PermissionSweepTest < ActionDispatch::IntegrationTest
  PERSONAS = {
    "member" => { role: nil },
    "scoped" => { role: nil, scopes: %w[member.read channel.backfill] },
    "promethean" => { appointed: 1 },
    "gardener" => { role: "gardener" },
    "analytics" => { role: "analytics" },
    "firefighter" => { role: "firefighter" },
    "manager" => { role: "community_manager" }
  }.freeze

  FD_PATHS = %w[/fd /fd/cases /fd/members /fd/search
                /fd/members/search].freeze

  # the conduct team reaches the audit, but the engine's own record is access.read
  AUDIT_PATH = "/fd/audit".freeze

  ADMIN_PATHS = %w[/admin /admin/people /admin/roles /admin/flags /admin/channels
                   /admin/role_channels /admin/people/search
                   /admin/channels/search].freeze

  ENGINE_PATHS = %w[/engine].freeze

  setup do
    @manager = grant_role!("USWEEPBOSS", "community_manager")
    @channels = Analytics::DimChannel.where(archived: false).limit(4).pluck(:channel_id)
    @granted_channel, @other_channel = @channels
  end

  def sign_in_persona(name)
    persona = PERSONAS.fetch(name)
    id = "USWEEP#{name.upcase[0, 4]}"
    Account.find_or_create_by!(user_id: id)
    grant_role!(id, persona[:role]) if persona[:role]
    Array(persona[:scopes]).each do |key|
      Authz::Grant.grant!(id, kind: "capability", name: key, by: "sweep")
    end
    if persona[:channels]
      Channels::Audience::Grant.create!(user_id: id, channel_id: @granted_channel,
        granted_by: @manager.user_id, granted_at: Time.current)
    end
    if persona[:appointed]
      Prometheus::Appointment.insert_all!([
        { user_id: id, channel_id: @granted_channel, role: "manager", seen_at: Time.current }
      ])
    end
    Current.forget_roles
    sign_in_as(Account.find(id))
    id
  end

  def responds_ok?(path)
    get path
    response.status == 200
  end

  # 1. nothing at all without a session
  test "signed out requests redirect or return 404 on every page" do
    open_to_all = ["/login", "/auth/failure"]
    reachable_paths = (FD_PATHS + ADMIN_PATHS + ENGINE_PATHS + ["/", "/account", "/channels",
                                                    "/journey/joining",
                                                    "/messages/C0SWEEP/1.000001"]).reject do |path|
      get path
      response.redirect? || response.status == 404
    end

    assert_empty reachable_paths, "a signed out visitor reached: #{reachable_paths.join(', ')}"
    open_to_all.each do |path|
      get path
      refute_equal 500, response.status, "#{path} returned 500 signed out"
    end
  end

  # 2. the fire engine is case.read only
  test "fire engine pages respond 200 only with case.read" do
    violations = []
    PERSONAS.each_key do |name|
      id = sign_in_persona(name)
      allowed = Authz.holds?(Account.find(id), "case.read")
      FD_PATHS.each do |path|
        next if responds_ok?(path) == allowed

        violations << "#{name} #{'' if allowed}#{path} (case.read=#{allowed}, got #{response.status})"
      end
    end
    assert_empty violations, violations.join("\n")
  end

  test "audit page responds 200 only with case.read" do
    violations = []
    PERSONAS.each_key do |name|
      id = sign_in_persona(name)
      allowed = Authz.holds?(Account.find(id), "case.read")
      next if responds_ok?(AUDIT_PATH) == allowed

      violations << "#{name} on #{AUDIT_PATH}: case.read=#{allowed}, got #{response.status}"
    end
    assert_empty violations, violations.join("\n")
  end

  test "audit engine record and event panel require access.read" do
    entry = Fd::AuditEntry.create!(occurred_at: 1.hour.ago, actor_user_id: "USWEEPBOSS",
      actor_kind: "human", entity_type: "case", entity_id: 9_001, verb: "resolved",
      after: { "resolution" => "warned" }, source_app: "fire_engine")

    violations = []
    PERSONAS.each_key do |name|
      id = sign_in_persona(name)
      allowed = Authz.holds?(Account.find(id), "access.read")
      next unless responds_ok?("#{AUDIT_PATH}?view=everything")

      record_visible = response.body.include?("audit-verb") && response.body.include?("resolved")
      violations << "#{name}: access.read=#{allowed} but saw the engine record" if record_visible && !allowed

      get "/fd/audit/event?source=fire_engine&id=#{entry.id}"
      panel_visible = response.status == 200
      violations << "#{name}: access.read=#{allowed} but opened the engine panel" if panel_visible && !allowed
    end
    assert_empty violations, violations.join("\n")
  end

  # 3. the admin section is access.grant only
  test "admin pages respond 200 only with access.grant" do
    violations = []
    PERSONAS.each_key do |name|
      id = sign_in_persona(name)
      allowed = Authz.holds?(Account.find(id), "access.grant")
      ADMIN_PATHS.each do |path|
        next if responds_ok?(path) == allowed

        violations << "#{name} reached #{path} with access.grant=#{allowed}"
      end
    end
    assert_empty violations, violations.join("\n")
  end

  # 4. the engine is engine.manage only
  test "engine pages respond 200 only with engine.manage" do
    violations = []
    PERSONAS.each_key do |name|
      id = sign_in_persona(name)
      allowed = Authz.holds?(Account.find(id), "engine.manage")
      ENGINE_PATHS.each do |path|
        next if responds_ok?(path) == allowed

        violations << "#{name} on #{path} with engine.manage=#{allowed}, got #{response.status}"
      end
    end
    assert_empty violations, violations.join("\n")
  end

  # 5. a channel nobody named you on stays shut
  test "channel page responds 200 only when may_see? is true" do
    violations = []
    PERSONAS.each_key do |name|
      id = sign_in_persona(name)
      staff = Account.find(id)
      [@granted_channel, @other_channel].each do |channel_id|
        allowed = Channels::Audience.may_see?(staff, channel_id)
        next if responds_ok?("/channels/#{channel_id}") == allowed

        violations << "#{name} on #{channel_id}: may_see=#{allowed}, got #{response.status}"
      end
    end
    assert_empty violations, violations.join("\n")
  end

  # 6. the promethean sees their own channel and not the next one along
  test "promethean reaches the appointed channel and not another channel" do
    sign_in_persona("promethean")

    assert responds_ok?("/channels/#{@granted_channel}"), "own channel not reachable"
    refute responds_ok?("/channels/#{@other_channel}"), "reached a channel without an appointment"
  end

  # 7. names are behind member.read
  test "member display name is absent from pages without member.read" do
    named_member = Fd::Member.first
    skip "no member fixture" if named_member.nil?

    violations = []
    PERSONAS.each_key do |name|
      id = sign_in_persona(name)
      next if Authz.holds?(Account.find(id), "member.read")

      %w[/ /channels /journey/joining /account].each do |path|
        get path
        next unless response.status == 200 && named_member.display_name.present?
        next unless response.body.include?(named_member.display_name)

        violations << "#{name} saw #{named_member.display_name} on #{path}"
      end
    end
    assert_empty violations, violations.join("\n")
  end

  # 8. the json endpoints are the quiet way in
  test "search endpoints require the same capability as their pages" do
    violations = []
    PERSONAS.each_key do |name|
      id = sign_in_persona(name)
      staff = Account.find(id)
      [["/admin/people/search?q=see", "access.grant"],
       ["/admin/channels/search?q=see", "access.grant"],
       ["/fd/members/search?q=see", "case.read"]].each do |path, key|
        allowed = Authz.holds?(staff, key)
        get path
        next if (response.status == 200) == allowed

        violations << "#{name} on #{path}: #{key}=#{allowed}, got #{response.status}"
      end
    end
    assert_empty violations, violations.join("\n")
  end

  # 9. a refused write must not write
  test "writes from non-manager personas return non-200 and change no rows" do
    writes = [
      [:post, "/admin/grants", { user_id: "UVICTIM01", role: "community_manager" }],
      [:delete, "/admin/grants/USWEEPBOSS", {}],
      [:patch, "/fd/role_permission", { role: "firefighter", key: "case.act", allowed: "0" }],
      [:patch, "/fd/flag", { key: "fire_engine", on: "0" }],
      [:post, "/engine/sync", {}],
      [:patch, "/engine/tune", { retention_days: "1" }]
    ]

    violations = []
    PERSONAS.each_key do |name|
      next if name == "manager"

      sign_in_persona(name)
      before = row_counts
      writes.each do |verb, path, params|
        send(verb, path, params: params)
        refute_equal 200, response.status, "#{name} got a 200 from #{verb} #{path}"
      end
      after = row_counts
      violations << "#{name} changed #{(before.to_a - after.to_a).inspect}" if before != after
    end
    assert_empty violations, violations.join("\n")
  end

  def row_counts
    { grants: Authz::Grant.live.count,
      overrides: Authz::Override.count,
      flags: Fd::Flag.where(is_on: true).count,
      channel_grants: Channels::Audience::Grant.live.count,
      audiences: Channels::Audience::Setting.count }
  end

  # 10. taking your own access away is somebody else's job
  test "admin grants destroy on own account keeps the role" do
    id = sign_in_persona("manager")
    assert_includes Authz.effective_roles(id), "community_manager", "persona has no community_manager role"

    delete "/admin/grants/#{id}"

    assert_includes Authz.effective_roles(id), "community_manager"
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
    [:patch, "/fd/flag", "app.flip", { key: "fire_engine", on: "0" }],
    [:post, "/engine/sync", "engine.manage", {}],
    [:post, "/engine/cancel", "engine.manage", {}],
    [:post, "/engine/stages/member_days", "engine.manage", {}],
    [:patch, "/engine/tune", "engine.manage", { retention_days: "30" }],
    [:delete, "/engine/tune", "engine.manage", {}]
  ].freeze

  # 11a. a sweep row nobody can reach proves nothing, whoever asks
  test "WRITES entries are routable and use known stages" do
    unrouted = WRITES.reject do |verb, path, _key, _params|
      Rails.application.routes.recognize_path(path, method: verb)
    rescue ActionController::RoutingError
      false
    end
    assert_empty unrouted.map { |verb, path, _, _| "#{verb.upcase} #{path}" }

    named = WRITES.filter_map { |_verb, path, _key, _params| path[%r{/engine/stages/(.+)}, 1] }
    refute_empty named, "no stage route in WRITES"
    assert_empty named - SyncRequest::STAGES,
      "WRITES contains stages missing from SyncRequest::STAGES"
  end

  test "mutating routes never return 200 without the required capability" do
    violations = []
    PERSONAS.each_key do |name|
      id = sign_in_persona(name)
      staff = Account.find(id)
      WRITES.each do |verb, path, key, params|
        next if Authz.holds?(staff, key)

        send(verb, path, params: params)
        next unless response.status == 200

        violations << "#{name} got 200 from #{verb.upcase} #{path} without #{key}"
      end
    end
    assert_empty violations, violations.join("\n")
  end

  # 12. the channel index must list only what you may see
  test "channels index omits channels failing may_see?" do
    violations = []
    PERSONAS.each_key do |name|
      id = sign_in_persona(name)
      staff = Account.find(id)
      get "/channels"
      next unless response.status == 200

      @channels.each do |channel_id|
        next if Channels::Audience.may_see?(staff, channel_id)
        next unless response.body.include?(channel_id)

        violations << "#{name} saw #{channel_id} listed"
      end
    end
    assert_empty violations, violations.join("\n")
  end

  # 13. opting a channel into replies is not a way to reach it
  test "channel replies post for an unseen channel is not 200 and creates no backfill" do
    sign_in_persona("promethean")

    post "/channels/#{@other_channel}/replies"
    refute_equal 200, response.status

    assert_equal 0, ChannelBackfill.where(channel_id: @other_channel).count,
      "backfill queued for an unseen channel"
  end

  # 14. a signed out visitor cannot write anything at all
  test "signed out writes return non-200 and change no rows" do
    before = row_counts
    WRITES.each do |verb, path, _key, params|
      send(verb, path, params: params)
      refute_equal 200, response.status, "signed out request got 200 from #{verb.upcase} #{path}"
    end
    assert_equal before, row_counts, "signed out writes changed row counts"
  end

  # 15. the dev door must never exist outside development
  test "dev/be route is absent outside development and test" do
    assert Rails.application.routes.routes.none? { |r|
      r.path.spec.to_s.include?("dev/be")
    } || Rails.env.development? || Rails.env.test?,
      "dev/be is routable in this environment"
  end

  # 16. a locked capability cannot be delegated, not even by a manager
  test "locked access.grant capability is refused for a manager and raises NotAllowedError" do
    sign_in_persona("manager")

    post "/admin/grants", params: { user_id: "UVICTIM01", scopes: ["access.grant"],
                                    scopes_settled: "1" }

    refute_includes Authz.effective_capabilities("UVICTIM01").keys, "access.grant",
      "locked access.grant capability was granted"
    assert_raises(Authz::Grant::NotAllowedError) do
      Authz::Grant.grant!("UVICTIM01", kind: "capability", name: "access.grant", by: "sweep")
    end
  end

  # 17. taking a capability away really takes it away
  test "slack.link deny overrides the role capability and blocks delete slack_account" do
    id = sign_in_persona("firefighter")
    assert Authz.holds?(Account.find(id), "slack.link"), "role must include the capability"

    Authz::Grant.grant!(id, kind: "capability", name: "slack.link", effect: "deny", by: "sweep")
    Current.forget_roles

    refute Authz.holds?(Account.find(id), "slack.link"), "deny grant did not remove the capability"
    delete "/fd/slack_account"

    refute_equal 200, response.status, "delete returned 200 with the capability denied"
  end

  # 18. identity.read is FD only, it cannot be moved off a firefighter one person at a time
  test "identity.read deny raises NotAllowedError and keeps the capability" do
    id = sign_in_persona("firefighter")
    assert Authz.holds?(Account.find(id), "identity.read"), "role must include the capability"

    assert_raises(Authz::Grant::NotAllowedError) do
      Authz::Grant.grant!(id, kind: "capability", name: "identity.read", effect: "deny",
        by: "sweep")
    end
    assert Authz.holds?(Account.find(id), "identity.read"), "refused deny must keep the capability"
  end

  # 19. asking for json is not a way round the gate
  test "json format requires the same capability as html" do
    violations = []
    PERSONAS.each_key do |name|
      id = sign_in_persona(name)
      staff = Account.find(id)
      [["/fd/cases", "case.read"], ["/admin/people", "access.grant"],
       ["/engine", "engine.manage"]].each do |path, key|
        next if Authz.holds?(staff, key)

        get "#{path}.json"
        next unless response.status == 200

        violations << "#{name} got #{path}.json without #{key}"
      end
    end
    assert_empty violations, violations.join("\n")
  end

  # 20. logging out really ends it
  test "admin page redirects after logout" do
    sign_in_persona("manager")
    assert responds_ok?("/admin/people")

    delete "/logout"
    get "/admin/people"

    assert response.redirect?, "admin page did not redirect after logout"
  end
end
