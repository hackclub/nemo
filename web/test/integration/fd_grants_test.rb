require "test_helper"

class FdGrantsTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def give(user_id: "U0AFF1", role: "firefighter", **rest)
    post admin_grants_path, params: { user_id: user_id, role: role }.merge(rest)
    Current.forget_roles
  end

  def held(user_id = "U0AFF1")
    Current.forget_roles
    Authz::Grant.live.roles.find_by(user_id: user_id)
  end

  test "giving access records the role and who gave it" do
    give

    grant = held
    assert_equal "firefighter", grant.name
    assert_equal "UME", grant.granted_by
    assert_redirected_to admin_person_path("U0AFF1")
    assert Fd::AuditEntry.exists?(entity_type: "capability_grant", entity_id: grant.id,
      verb: "granted")
  end

  test "a grant needs somebody" do
    give(user_id: "")
    assert_match(/search for somebody/, flash[:alert])

    give(user_id: "not-an-id")
    assert_match(/is not a Slack user id/, flash[:alert])

    assert_equal 0, Authz::Grant.for_person("U0AFF1").count
  end

  test "changing a role ends the old grant and starts a new one" do
    give
    give(role: "gardener")

    assert_equal "gardener", held.name
    assert_equal 2, Authz::Grant.for_person("U0AFF1").roles.count
    assert_equal 1, Authz::Grant.for_person("U0AFF1").roles.where.not(revoked_at: nil).count
  end

  test "taking everything back leaves the person holding nothing, and says so in the trail" do
    give
    grant = held

    delete admin_grant_path("U0AFF1")

    assert_nil held
    assert_equal "UME", grant.reload.revoked_by
  end

  test "unpicking the fire department rung takes that grant back" do
    give
    grant = held

    post admin_grants_path, params: { user_id: "U0AFF1" }

    assert_nil held
    assert Fd::AuditEntry.exists?(entity_type: "capability_grant", entity_id: grant.id,
      verb: "revoked")
  end

  test "the last manager cannot lock everybody out by taking their own back" do
    delete admin_grant_path("UME")

    assert_match(/somebody else has to take yours back/, flash[:alert])
    assert_predicate Account.find("UME"), :manager?
  end

  test "a lead cannot reach the grant endpoints at all" do
    delete logout_path
    hand = Account.create!(user_id: "ULEAD")
    Authz::Grant.give!("ULEAD", kind: "role", name: "firefighter", by: "UME")
    Current.forget_roles
    sign_in_as(hand)

    give

    assert_nil held
    assert_redirected_to root_path
  end

  test "making somebody a manager is written to the trail, and ends their old role" do
    give
    post admin_grants_path, params: { user_id: "U0AFF1", role: "community_manager" }
    Current.forget_roles

    assert_predicate Account.find("U0AFF1"), :manager?
    assert_equal "community_manager", held.name
    assert_equal 1, Authz::Grant.for_person("U0AFF1").roles.where.not(revoked_at: nil).count
    assert Fd::AuditEntry.where(verb: "granted")
      .any? { |row| row.after&.dig("role") == "community_manager" }
  end

  test "no form on the settings page sits inside another one" do
    Authz::Grant.give!("U0AFF1", kind: "role", name: "firefighter", by: "UME")
    Current.forget_roles

    get admin_person_path("U0AFF1")

    assert_select "form form", count: 0
  end

  test "the edit modal posts the person it is about, prefilled with what they hold" do
    Authz::Grant.give!("U0AFF1", kind: "role", name: "firefighter", by: "UME")
    Current.forget_roles
    get admin_person_path("U0AFF1")

    assert_select "form[action=?]", admin_grants_path do
      assert_select "input[name=user_id][value=?]", "U0AFF1"
      assert_select "input[name=role][value=firefighter][checked]"
    end
  end

  test "the controls are only drawn for somebody who may use them" do
    Authz::Grant.give!("U0AFF1", kind: "role", name: "firefighter", by: "UME")

    get admin_people_path
    assert_select "button[data-modal-open=give-access]", text: "Give access"

    get admin_person_path("U0AFF1")
    assert_select "button[data-modal-open=give-access]", text: "Edit access"

    delete logout_path
    lead = Account.create!(user_id: "ULEAD")
    Authz::Grant.give!("ULEAD", kind: "role", name: "firefighter", by: "UME")
    sign_in_as(lead)

    get admin_people_path
    assert_redirected_to root_path, "the admin section is managers only"
  end

  test "a reason is kept on the grant when one is given" do
    give(reason: "covering the weekend")

    assert_equal "covering the weekend", held.reason
  end

  test "a grant without a reason is still allowed, since the field is optional" do
    give

    grant = held
    assert_nil grant.reason
    assert_equal "firefighter", grant.name
  end

  test "a blank reason is stored as nothing rather than an empty string" do
    give(reason: "   ")

    assert_nil held.reason
  end

  test "the give modal offers one role, searchable scopes and a channel picker" do
    get admin_people_path

    assert_select "#give-access ~ * .seg-radio input[name=role]", Authz.grantable_roles.size,
      "every grantable role, and unpicking one clears it"
    grantable = Authz.keys.reject { |key| Authz.locked?(key) || Authz.every_account?(key) }
    assert_select "#give-access ~ * input[name=?]", "scopes[]", grantable.size,
      "every capability you may hand out is tickable"
    assert_select "#give-access ~ * [data-controller=channel-picker]", 1
    assert_select "#give-access ~ * input[name=reason]", 1
  end

  test "the modal no longer offers a role that cannot be granted" do
    get admin_people_path

    %w[observer analyst curator operator steward lead].each do |gone|
      assert_select "#give-access ~ * input[value='#{gone}']", false,
        "#{gone} is not a role any more"
    end
  end

  test "naming a channel on somebody with no role gives them channel.read" do
    channel = Analytics::DimChannel.where(archived: false).first

    post admin_grants_path, params: { user_id: "U0AFF1", role: "",
      channels: [channel.channel_id] }
    Current.forget_roles

    assert_equal ["promethean"], Authz.roles_held("U0AFF1")
    assert_equal "baseline", Authz.held("U0AFF1")["channel.read"]
  end

  test "granting a role, a scope and a channel is one act" do
    channel = Analytics::DimChannel.where(archived: false).first

    post admin_grants_path, params: { user_id: "U0AFF1", role: "promethean",
      scopes: ["engine.stage"], channels: [channel.channel_id], reason: "the sync rota" }
    Current.forget_roles

    assert_equal "promethean", held.name
    got = Authz.held("U0AFF1")
    assert_equal "added", got["engine.stage"]
    assert_equal "baseline", got["channel.read"],
      "promethean already carries channel.read, so it is not granted twice"
    assert Channels::Audience::Grant.live
      .exists?(user_id: "U0AFF1", channel_id: channel.channel_id)
  end
end
