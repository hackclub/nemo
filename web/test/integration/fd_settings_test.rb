require "test_helper"

class FdSettingsTest < ActionDispatch::IntegrationTest
  setup do
    Fd::AccessGrant.where("user_id LIKE 'USEED%'").delete_all
    @bootstrap_was = ENV["BOOTSTRAP_ADMIN_SLACK_ID"]
    ENV["BOOTSTRAP_ADMIN_SLACK_ID"] = "UME"
    @me = Staff.create!(user_id: "UME")
    sign_in_as(@me)
  end

  teardown do
    ENV["BOOTSTRAP_ADMIN_SLACK_ID"] = @bootstrap_was
  end

  def give(user_id, role: "firefighter", **attrs)
    Fd::AccessGrant.give!(user_id, role: role, by: "UME", **attrs)
  end

  def used_for(key)
    row = css_select("tr").find { |tr| tr.css("td.mono").text.strip == key }
    row&.css("td")&.last&.text.to_s.strip
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
    assert_select ".chip.chip-off", text: "firefighter"
    assert_select ".chip.chip-warn", text: "lead"
    assert_select "td", text: /UFF1/
  end

  test "the roster counts itself by role" do
    Fd::AccessGrant.delete_all
    give("UFF1")
    give("UFF2")
    give("ULEAD", role: "lead")

    get fd_settings_path

    assert_select ".view[aria-current] .view-count", text: "3"
    assert_select ".chip", text: "lead"
    assert_select ".chip", text: "firefighter", minimum: 2
  end

  test "an empty roster says so" do
    Fd::AccessGrant.delete_all
    get fd_settings_path

    assert_select ".empty-title", text: "Nobody holds a grant yet"
  end

  test "a grant nobody has used in a month is called out" do
    give("UQUIET", at: 3.months.ago)
    give("UBUSY")
    Fd::AuditEntry.create!(actor_user_id: "UBUSY", actor_kind: "human", entity_type: "case",
      entity_id: 1, verb: "opened", source_app: "fire_engine")

    get fd_settings_path

    assert_select ".todo-t", text: /UQUIET has held a firefighter grant/
    assert_select ".todo", count: 1
  end

  test "a fresh grant is not called dormant" do
    give("UNEW")
    get fd_settings_path

    assert_select ".todo", count: 0
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

  test "the roles tab lists every permission, grouped the way the app is" do
    get fd_settings_path(tab: "roles")

    assert_response :success
    assert_select ".band-row", text: /Cases · 11/
    assert_select ".band-row", text: /Decisions · 4/
    assert_select ".band-row", text: /People and access · 4/
    assert_select "td.mono", text: "case.reverse"
    assert_select "td.mono", count: Fd::Permission.keys.size
  end

  test "each row says which roles hold it" do
    get fd_settings_path(tab: "roles")

    assert_select "tr", text: /case\.act.*yes.*yes.*yes/m
    assert_select "tr", text: /decision\.settle.*no.*yes.*yes/m
    assert_select "tr", text: /access\.grant.*no.*no.*yes/m
  end

  test "the roles tab counts how often each permission was used" do
    get fd_settings_path(tab: "roles")
    before = used_for("case.act").to_i
    reads = used_for("identity.read").to_i

    Fd::AuditEntry.create!(actor_user_id: "UME", actor_kind: "human", entity_type: "action",
      entity_id: 1, verb: "performed", source_app: "fire_engine")
    Fd::AuditEntry.create!(actor_user_id: "UME", actor_kind: "human", entity_type: "action",
      entity_id: 2, verb: "performed", source_app: "fire_engine", occurred_at: 2.months.ago)
    AccessLog.create!(actor_id: "UME", subject_user_id: "USUB", field_class: "identity",
      looked_at: 1.day.ago)

    get fd_settings_path(tab: "roles")

    assert_equal before + 1, used_for("case.act").to_i, "only the row inside the window counts"
    assert_equal reads + 1, used_for("identity.read").to_i
  end

  test "the usage tab counts the load per person and ranks by it" do
    give("UBUSY")
    give("UQUIET")
    3.times do |n|
      Fd::AuditEntry.create!(actor_user_id: "UBUSY", actor_kind: "human", entity_type: "action",
        entity_id: n + 1, verb: "performed", source_app: "fire_engine")
    end
    Fd::AuditEntry.create!(actor_user_id: "UQUIET", actor_kind: "human", entity_type: "case",
      entity_id: 7, verb: "opened", source_app: "fire_engine")

    get fd_settings_path(tab: "usage")

    assert_response :success
    rows = css_select("tbody tr")
    assert_equal ["UBUSY", "UQUIET"], rows.first(2).map { |tr| tr.css("a").first["href"][/U\w+/] }
    assert_equal %w[0 3 0 0], rows[0].css("td.col-num").map { |td| td.text.strip },
      "cases, actions, reversed, refused: reads have their own box now"
    assert_equal %w[1 0 0 0], rows[1].css("td.col-num").map { |td| td.text.strip }
  end

  test "identity reads get a box of their own, ranked" do
    give("UREADER")
    3.times do |n|
      AccessLog.create!(actor_id: "UREADER", subject_user_id: "USUB#{n}",
        field_class: "identity", looked_at: 1.day.ago)
    end

    get fd_settings_path(tab: "usage")

    assert_select "th", { text: "Reads", count: 0 }, "it is not a column any more"
    assert_select ".facts .fbox .bar-row .row-v", text: "3"
    assert_select ".facts .fbox .bar-row .bar-fill"
  end

  test "a refusal counts as a refusal, not as work done" do
    give("UFF1")
    Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "case",
      entity_id: 0, verb: "refused", source_app: "fire_engine",
      after: { "permission" => "decision.settle", "role" => "firefighter" })

    get fd_settings_path(tab: "usage")

    row = css_select("tbody tr").find { |tr| tr.to_s.include?("UFF1") }
    assert_equal %w[0 0 0 1], row.css("td.col-num").map { |td| td.text.strip }
    assert_select ".bar.warm"
  end

  test "the usage headline counts reads, refusals and grants that moved" do
    give("UFF1")
    get fd_settings_path(tab: "usage")
    before = css_select(".facts .fg-v").map { |node| node.text.strip.to_i }

    AccessLog.create!(actor_id: "UFF1", subject_user_id: "USUB", field_class: "identity",
      looked_at: 1.day.ago)
    AccessLog.create!(actor_id: "UFF1", subject_user_id: "UOTHER", field_class: "identity",
      looked_at: 2.months.ago)
    Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "case",
      entity_id: 0, verb: "refused", source_app: "fire_engine",
      after: { "permission" => "access.grant", "role" => "firefighter" })

    get fd_settings_path(tab: "usage")
    after = css_select(".facts .fg-v").map { |node| node.text.strip.to_i }

    assert_equal before[0], after[0], "nobody was given or lost a grant"
    assert_equal before[1] + 1, after[1], "only the read inside the window counts"
    assert_equal before[2] + 1, after[2], "the refusal counts"
    assert_equal before[3], after[3], "the fresh grant is not dormant yet"
    assert_select ".facts .rail-line", text: /access\.grant/
  end

  test "a grant nobody has used shows up as unused, with who holds it" do
    give("UQUIET", at: 4.months.ago)

    get fd_settings_path(tab: "usage")

    assert_select ".facts .fg-k", text: "Unused"
    assert_select ".facts .rail-line .chip.chip-warn", text: /UQUIET, 4mo/
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
    assert_select ".inspector", { count: 0 },
      "the second roster duplicated the table you just left"
    assert_select ".panel .who .two-line b", text: /UFF1/
    assert_select ".panel .who .two-line span", text: /given by @UME/
    assert_select ".panel .outcome", text: /night shift while sam is away/
  end

  test "one person on the usage tab counts what they did, by permission" do
    give("UFF1")
    3.times do |n|
      Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "action",
        entity_id: n + 1, verb: "performed", source_app: "fire_engine")
    end
    Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "case",
      entity_id: 1, verb: "opened", source_app: "fire_engine", occurred_at: 2.months.ago)

    get fd_settings_path(tab: "usage", person: "UFF1")

    assert_select ".fbox .row", text: /Log an action.*case\.act.*3/m
    assert_select ".fbox .row", text: /Open a case/, count: 0
    assert_select ".stat-row .fg-v", text: "3"
  end

  test "a claim counts towards opening a case, which is where it is audited" do
    give("UFF1")
    Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "assignee",
      entity_id: 41, verb: "claimed", source_app: "fire_engine")

    get fd_settings_path(tab: "usage", person: "UFF1")

    assert_select ".fbox .row", text: /Open a case, claim it.*case\.open.*1/m
    assert_select ".fbox .row", text: /Claimed case 41/
  end

  test "the person view shows the work itself, not just how much of it there was" do
    give("UFF1")
    kase = make_case
    action = Fd::Action.create!(case_id: kase.id, type_key: "temp_ban", target_user_id: "USUB",
      decided_by: "UFF1", performed_by: "UFF1")
    Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "action",
      entity_id: action.id, verb: "performed", source_app: "fire_engine")

    get fd_settings_path(tab: "usage", person: "UFF1")

    assert_select ".fbox .row", text: /Logged an action on case #{kase.id}.*temp ban on/m
    assert_select ".fbox .row a[href=?]", fd_case_path(kase)
  end

  test "a number in the usage table opens that person filtered to it" do
    give("UFF1")
    Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "action",
      entity_id: 1, verb: "performed", source_app: "fire_engine")

    get fd_settings_path(tab: "usage")

    assert_select "td a[href=?]",
      fd_settings_path(tab: "usage", person: "UFF1", did: "case.act"), text: "1"
  end

  test "asking for one permission narrows the list to it" do
    give("UFF1")
    kase = make_case
    Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "case",
      entity_id: kase.id, verb: "opened", source_app: "fire_engine")
    AccessLog.create!(actor_id: "UFF1", subject_user_id: "USUB", field_class: "identity",
      looked_at: 1.day.ago)

    get fd_settings_path(tab: "usage", person: "UFF1", did: "identity.read")

    assert_select "a.row[aria-current='true']", text: /identity\.read/
    assert_select ".fbox .row", text: /Read the identity of/
    assert_select ".fbox .row", text: /Opened case/, count: 0
  end

  test "the permission already asked for links back to everything" do
    give("UFF1")
    Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "case",
      entity_id: 1, verb: "opened", source_app: "fire_engine")

    get fd_settings_path(tab: "usage", person: "UFF1", did: "case.open")

    assert_select "a.row[aria-current='true'][href=?]",
      fd_settings_path(tab: "usage", person: "UFF1")
  end

  test "the pane lists what the role does not cover" do
    give("UFF1")
    get fd_settings_path(person: "UFF1")

    assert_select ".ft", text: /What the role does not cover\s*5/
    assert_select ".fbox .row", text: /Settle a proposal.*lead only/m
    assert_select ".fbox .row", text: /Give or take back access.*community manager only/m
  end

  test "a lead is short of only what the manager keeps" do
    give("ULEAD", role: "lead")
    get fd_settings_path(person: "ULEAD")

    assert_select ".ft", text: /What the role does not cover\s*3/
  end

  test "identity reads are counted for everybody, since everybody may read" do
    give("UFF1")
    AccessLog.create!(actor_id: "UFF1", subject_user_id: "USUB", field_class: "identity",
      looked_at: 2.days.ago)

    get fd_settings_path(tab: "usage", person: "UFF1")

    assert_select ".fbox .row", text: /Identity reads.*1/m
  end

  test "the person view keeps the refusals, and says so when there are none" do
    give("UFF1")
    get fd_settings_path(tab: "usage", person: "UFF1")
    assert_select ".sub2", text: "Never refused."

    Fd::AuditEntry.create!(actor_user_id: "UFF1", actor_kind: "human", entity_type: "case",
      entity_id: 41, verb: "refused", source_app: "fire_engine",
      after: { "permission" => "case.reverse", "role" => "firefighter" })

    get fd_settings_path(tab: "usage", person: "UFF1")
    assert_select ".ft", text: /Refused\s*1/
    assert_select ".fbox .row", text: /Reverse an action.*case 41/m
  end

  test "asking for somebody who holds nothing shows the roster" do
    give("UFF1")
    get fd_settings_path(person: "UNOBODY")

    assert_select ".inspector", count: 0
    assert_select ".data-table"
  end

  test "a firefighter gets settings, lands on their own tab, and no further" do
    hand = Staff.create!(user_id: "UHAND")
    give("UHAND")
    sign_in_as(hand)

    get fd_cases_path
    assert_select ".you-menu .menu-pop a[href=?]", fd_settings_path, 1

    get fd_settings_path
    assert_response :success
    assert_select ".ft", text: /Your Slack account/
    assert_select ".data-table", count: 0

    get fd_settings_path(tab: "access")
    assert_redirected_to fd_cases_path
    assert_equal 1, Fd::AuditEntry.where(verb: "refused", actor_user_id: "UHAND").count
  end

  test "the flag on a staff row no longer outranks the grant they hold" do
    ENV["BOOTSTRAP_ADMIN_SLACK_ID"] = nil
    flagged = Staff.create!(user_id: "UFLAGGED", community_manager: true)
    assert_equal "community_manager", flagged.reload.role, "seeding the flag issues a real grant"

    give("UFLAGGED")
    sign_in_as(flagged)

    get fd_settings_path(tab: "access")
    assert_redirected_to fd_cases_path, "the grant demoted them, the flag is still set"
  end
end
