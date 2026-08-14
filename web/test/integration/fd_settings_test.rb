require "test_helper"

class FdSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
  end

  def give(user_id, role: "firefighter", **attrs)
    Fd::AccessGrant.give!(user_id, role: role, by: "UME", **attrs)
  end

  test "a signed out visitor sees nothing" do
    delete logout_path
    get fd_settings_path
    assert_redirected_to login_path
  end

  test "the roster lists who holds what, and who gave it" do
    give("UFF1", reason: "night shift")
    give("ULEAD", role: "lead")

    get fd_settings_path

    assert_response :success
    assert_select ".head-title", text: "Settings"
    assert_select ".chip.chip-off", text: "firefighter"
    assert_select ".chip.chip-warn", text: "lead"
    assert_select "td", text: /UFF1/
  end

  test "the subtitle counts the roster by role" do
    Fd::AccessGrant.delete_all
    give("UFF1")
    give("UFF2")
    give("ULEAD", role: "lead")

    get fd_settings_path
    assert_select ".head-meta", text: /3 people · 1 lead · 2 firefighters/
  end

  test "an empty roster says so" do
    Fd::AccessGrant.delete_all
    get fd_settings_path

    assert_select ".card-note", text: "Nobody holds a grant yet."
  end

  test "a grant nobody has used in a month is called out" do
    give("UQUIET", at: 3.months.ago)
    give("UBUSY")
    Fd::AuditEntry.create!(actor_user_id: "UBUSY", actor_kind: "human", entity_type: "case",
      entity_id: 1, verb: "opened", source_app: "fire_engine")

    get fd_settings_path

    assert_select ".strip b", text: /UQUIET has held a firefighter grant/
    assert_select ".strip", count: 1
  end

  test "a fresh grant is not called dormant" do
    give("UNEW")
    get fd_settings_path

    assert_select ".strip", count: 0
  end

  test "the roster says when each person last acted" do
    give("UBUSY")
    Fd::AuditEntry.create!(actor_user_id: "UBUSY", actor_kind: "human", entity_type: "case",
      entity_id: 1, verb: "opened", source_app: "fire_engine", occurred_at: 2.days.ago)

    get fd_settings_path

    assert_select "td.col-num", text: "1"
    assert_select "td", text: /ago/
  end

  test "the history tab keeps the grants that ended" do
    grant = give("UGONE", reason: "left FD")
    grant.take_back!(by: "UME")
    give("UHERE", reason: "still here")

    get fd_settings_path(tab: "history")

    assert_select ".said-cell", text: "left FD"
    assert_select ".chip.chip-off", text: "ended"
    assert_select ".chip.chip-good", text: "live"
  end

  test "a tab nobody offered falls back to the roster" do
    give("UFF1")
    get fd_settings_path(tab: "vibes")

    assert_select ".view[aria-current]", text: /Access/
  end

  test "a person opens beside the roster, with their grant and its reason" do
    give("UFF1", reason: "night shift while sam is away")

    get fd_settings_path(person: "UFF1")

    assert_response :success
    assert_select ".inspector .index-item[aria-current]", text: /UFF1/
    assert_select ".mcard-sub", text: /given by @UME/
    assert_select ".mcard-sub", text: /night shift while sam is away/
  end

  test "the pane counts what they did with the grant, by permission" do
    give("UFF1")
    3.times do |n|
      Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "action",
        entity_id: n + 1, verb: "performed", source_app: "fire_engine")
    end
    Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "case",
      entity_id: 1, verb: "opened", source_app: "fire_engine", occurred_at: 2.months.ago)

    get fd_settings_path(person: "UFF1")

    assert_select ".line-row", text: /Log an action.*case\.act.*3/m
    assert_select ".line-row", text: /Open a case/, count: 0
  end

  test "the pane lists what the role does not cover" do
    give("UFF1")
    get fd_settings_path(person: "UFF1")

    assert_select ".band-label", text: /What the role does not cover · 7/
    assert_select ".line-row", text: /Reverse an action.*lead only/m
    assert_select ".line-row", text: /Give or take back access.*community manager only/m
  end

  test "a lead is short of only the two the manager keeps" do
    give("ULEAD", role: "lead")
    get fd_settings_path(person: "ULEAD")

    assert_select ".band-label", text: /What the role does not cover · 2/
  end

  test "a firefighter reads no identities, and it says so rather than zero" do
    give("UFF1")
    get fd_settings_path(person: "UFF1")

    assert_select ".line-row", text: /Identity reads.*n\/a/m
  end

  test "the pane keeps the refusals, and says so when there are none" do
    give("UFF1")
    get fd_settings_path(person: "UFF1")
    assert_select ".card-note", text: "Never refused."

    Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "case",
      entity_id: 41, verb: "refused", source_app: "fire_engine",
      after: { "permission" => "case.reverse", "role" => "firefighter" })

    get fd_settings_path(person: "UFF1")
    assert_select ".band-label", text: /Refused · 1/
    assert_select ".line-row", text: /Reverse an action.*case 41/m
  end

  test "asking for somebody who holds nothing shows the roster" do
    give("UFF1")
    get fd_settings_path(person: "UNOBODY")

    assert_select ".inspector", count: 0
    assert_select ".data-table"
  end

  test "the rail carries settings" do
    get fd_settings_path
    assert_select ".rail-item[aria-current='page']", text: /Settings/
  end
end
