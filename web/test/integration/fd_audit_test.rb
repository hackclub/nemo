require "test_helper"

class FdAuditTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables
  WHO = "USUB".freeze

  setup do
    @me = hold_role!("UME", "community_manager")
  end

  def engine!(verb: "opened", actor: "UME", kind: "human", entity: "case", id: 1,
    subject: nil, before: nil, after: nil, at: 1.hour.ago)
    Fd::AuditEntry.create!(occurred_at: at, actor_user_id: actor, actor_kind: kind,
      entity_type: entity, entity_id: id, verb: verb, subject_user_id: subject,
      before: before, after: after, source_app: "fire_engine")
  end

  def slack!(action: "user_login", actor: WHO, at: 1.hour.ago, ip: "81.2.69.144",
    id: SecureRandom.uuid, ours: false, email: nil)
    as_pipeline(<<~SQL.squish, id,
      INSERT INTO slack.audit_event (id, at, action, actor_kind, actor_id, entity_kind,
                                     entity_id, ours, context, payload, source_key)
      VALUES (?, ?, ?, 'user', ?, 'user', ?, ?, ?::jsonb, ?::jsonb, 'test')
    SQL
      at, action, actor, actor, ours, { ip_address: ip }.to_json,
      { id: id, action: action,
        actor: { type: "user", user: { id: actor, email: email }.compact } }.to_json)
    seeded!("slack.audit_event", "id", id)
  end

  def query(params = {})
    Fd::AuditQuery.new({ "view" => "everything" }.merge(params.stringify_keys), actor: @me)
  end

  test "one page holds what the engine did and what slack saw" do
    engine!(verb: "resolved")
    slack!(action: "user_login")

    sources = query.rows.map(&:source).uniq
    assert_includes sources, "fire_engine"
    assert_includes sources, "slack"
  end

  test "a tab narrows to one source without losing the others' counts" do
    engine!
    slack!
    AccessLog.record!(actor: @me, subject_user_id: WHO, field_class: "identity")

    assert_equal ["fire_engine"], query("view" => "engine").rows.map(&:source).uniq
    assert_equal ["slack"], query("view" => "slack").rows.map(&:source).uniq
    assert_equal ["read"], query("view" => "reads").rows.map(&:source).uniq

    counts = query("view" => "slack").views.index_by(&:key)
    assert_equal 1, counts["engine"].count, "a tab must not narrow the other tabs' counts"
    assert_equal 1, counts["reads"].count
  end

  test "our own reads of the audit log are left out of it" do
    slack!(action: "public_channel_preview", ours: true)
    slack!(action: "user_login", ours: false)

    assert_equal %w[user_login], query("view" => "slack").rows.map(&:verb)
  end

  test "refusals are their own tab and are kept out of everything else" do
    engine!(verb: "refused", entity: "permission")
    engine!(verb: "opened")

    assert_equal %w[refused], query("view" => "refusals").rows.map(&:verb)
    assert_not_includes query("view" => "engine").rows.map(&:verb), "refused"
  end

  test "nothing is hidden by a window, the record is all of it" do
    engine!(verb: "opened", at: 2.hours.ago)
    engine!(verb: "resolved", at: 3.years.ago)

    assert_equal 2, query.rows.size
    assert_equal %w[resolved], query("q" => "before:#{2.years.ago.to_date}").rows.map(&:verb)
    assert_equal %w[opened], query("q" => "after:#{1.year.ago.to_date}").rows.map(&:verb)
  end

  test "searching reaches into what actually changed" do
    engine!(verb: "categorised", after: { "category_key" => "harassment" })
    engine!(verb: "opened", after: { "category_key" => "spam" })

    assert_equal %w[categorised], query("q" => "harassment").rows.map(&:verb)
  end

  test "a search finds a slack event by the address it came from" do
    slack!(ip: "203.0.113.9")
    slack!(ip: "198.51.100.4", id: SecureRandom.uuid)

    found = query("q" => "203.0.113.9").rows
    assert_equal 1, found.size
    assert_equal "203.0.113.9", found.first.ip
  end

  test "a filter on who it was about reaches both logs" do
    engine!(subject: WHO, verb: "performed")
    engine!(subject: "UOTHER", verb: "noted")
    slack!(actor: WHO)

    found = query("q" => "about:#{WHO}").rows
    assert_equal %w[performed user_login].sort, found.map(&:verb).sort
  end

  test "a filter on what happened narrows to that verb" do
    engine!(verb: "opened")
    engine!(verb: "resolved")

    assert_equal %w[resolved], query("q" => "did:resolved").rows.map(&:verb)
  end

  test "nemo's own writing can be told from a person's" do
    engine!(actor: "UME", kind: "human", verb: "opened")
    engine!(actor: nil, kind: "bot", verb: "lifted")

    assert_equal %w[opened], query("q" => "is:person").rows.map(&:verb)
    assert_equal %w[lifted], query("q" => "is:nemo").rows.map(&:verb)
  end

  test "a page carries on from the last row rather than counting an offset" do
    3.times { |n| engine!(verb: "opened", id: n + 1, at: (n + 1).hours.ago) }

    first = query
    assert_not_nil first.rows.last
    carried = first.to_params.merge("before_at" => first.rows.last.at.iso8601(6),
      "before_id" => first.rows.last.id)
    assert_empty Fd::AuditQuery.new(carried, actor: @me).rows
  end

  test "a row says which fields moved and what they were" do
    engine!(verb: "categorised", before: { "category_key" => "spam" },
      after: { "category_key" => "harassment" })

    row = query.rows.first
    assert row.diff?
    assert_equal %w[category_key], row.changed_keys
    assert_equal "spam", row.was("category_key")
    assert_equal "harassment", row.now("category_key")
  end

  test "a slack event carries no diff, because slack does not tell us one" do
    slack!

    assert_not query("view" => "slack").rows.first.diff?
  end

  test "the page opens and lists both logs" do
    engine!(verb: "resolved")
    slack!
    sign_in_as(@me)

    get fd_audit_path
    assert_response :success
    assert_select ".audit-table"
    assert_match "resolved", response.body
    assert_match "user login", response.body
  end

  test "an address finds the events from it and everybody who used it" do
    slack!(ip: "86.12.44.9", actor: WHO)
    slack!(ip: "198.51.100.4", actor: "UOTHER", id: SecureRandom.uuid)

    found = query("q" => "86.12.44.9").rows
    assert_equal 1, found.size
    assert_equal "86.12.44.9", found.first.ip
  end

  test "a range finds every address inside it" do
    slack!(ip: "86.12.44.9")
    slack!(ip: "86.12.44.200", id: SecureRandom.uuid)
    slack!(ip: "198.51.100.4", id: SecureRandom.uuid)

    assert_equal 2, query("q" => "ip:86.12.44.0/24").rows.size
  end

  test "an email reaches the person behind it" do
    member!(WHO, email: "kid@school.example")
    engine!(subject: WHO, verb: "performed")
    engine!(subject: "UOTHER", verb: "noted")

    assert_equal %w[performed], query("q" => "kid@school.example").rows.map(&:verb)
    assert_equal %w[performed], query("q" => "domain:school.example").rows.map(&:verb)
  end

  test "an email slack carried is found even when we hold no identity for them" do
    slack!(email: "kid@throwaway.example", actor: "UKID")
    slack!(email: "someone@else.example", actor: "UELSE", id: SecureRandom.uuid)

    assert_equal 1, query("q" => "kid@throwaway.example").rows.size
    assert_equal 1, query("q" => "domain:throwaway.example").rows.size
  end

  test "a whole email handed to domain is read as its domain" do
    slack!(email: "kid@throwaway.example", actor: "UKID")

    asked = Fd::AuditSearch.parse("domain:kid@throwaway.example")
    assert_equal [["domain", "throwaway.example"]], asked.terms.map { |one| [one.kind, one.said] }
    assert_equal 1, query("q" => "domain:kid@throwaway.example").rows.size
  end

  test "a bare domain handed to email is read as a domain" do
    asked = Fd::AuditSearch.parse("email:throwaway.example")
    assert_equal [["domain", "throwaway.example"]], asked.terms.map { |one| [one.kind, one.said] }
  end

  test "an email nobody may read finds nothing rather than everything" do
    engine!(subject: WHO, verb: "performed")

    blind = Fd::AuditQuery.new({ "when" => "any", "q" => "kid@school.example" }, actor: nil)
    assert_empty blind.rows
  end

  test "a term the parser cannot place falls back to searching the text" do
    engine!(verb: "categorised", after: { "category_key" => "harassment" })

    said = Fd::AuditSearch.parse("harassment")
    assert_equal %w[text], said.terms.map(&:kind)
    assert_equal %w[categorised], query("q" => "harassment").rows.map(&:verb)
  end

  test "a chip can be taken off without losing the rest of the search" do
    asked = query("q" => "about:#{WHO} did:resolved")
    first = asked.terms.first

    left = asked.without_params(first)["q"]
    assert_not_includes left.to_s, first.said
    assert_includes left.to_s, "resolved"
  end

  test "the page opens on slack, since that is the log with the volume" do
    sign_in_as(@me)

    get fd_audit_path
    assert_select %(.view[aria-current="true"]), text: /Slack/
    assert_select ".segmented", false, "the range control is gone, the search carries it"
    assert_select ".ractions .qsearch"
  end

  test "the help is a dialog that can actually be opened" do
    sign_in_as(@me)

    get fd_audit_path
    assert_select %(button[data-modal-open="audit-help"])
    assert_select "#audit-help.modal-flip"
    assert_select ".audit-help-try", minimum: 5
  end

  test "the dots open a panel with the whole event, not a menu" do
    id = SecureRandom.uuid
    slack!(id: id, action: "user_profile_updated")
    sign_in_as(@me)

    get fd_audit_path
    assert_select %(a[data-turbo-frame="audit-panel"]), 1
    assert_select "turbo-frame#audit-panel"
    assert_no_match(/audit-panel-raw/, response.body, "the payload must not ride along in the table")

    get fd_audit_event_path(source: "slack", id: id)
    assert_response :success
    assert_select "turbo-frame#audit-panel .audit-panel-raw"
    assert_match "user_profile_updated", response.body
  end

  test "a panel for an event that is not there is a miss, not a crash" do
    sign_in_as(@me)

    get fd_audit_event_path(source: "slack", id: SecureRandom.uuid)
    assert_response :not_found

    get fd_audit_event_path(source: "nonsense", id: "1")
    assert_response :not_found
  end

  test "a fire engine panel shows what changed rather than a slack payload" do
    entry = engine!(verb: "resolved", before: { "resolution" => nil },
      after: { "resolution" => "warned" })
    sign_in_as(@me)

    get fd_audit_event_path(source: "fire_engine", id: entry.id.to_s)
    assert_response :success
    assert_match "resolved", response.body
    assert_match "warned", response.body
  end

  def in_channel!(channel_id, action: "user_channel_join")
    id = SecureRandom.uuid
    as_pipeline(<<~SQL.squish,
      INSERT INTO slack.audit_event (id, at, action, actor_kind, actor_id, entity_kind,
                                     entity_id, ours, context, payload, source_key)
      VALUES (?, now(), ?, 'user', ?, 'channel', ?, false, '{}'::jsonb, '{}'::jsonb, 'test')
    SQL
      id, action, WHO, channel_id)
    seeded!("slack.audit_event", "id", id)
  end

  def named_channel!(channel_id, name)
    as_pipeline(<<~SQL.squish,
      INSERT INTO raw.channel_dim (channel_id, name, visibility)
      VALUES (?, ?, 'public')
      ON CONFLICT (channel_id) DO UPDATE SET name = EXCLUDED.name
    SQL
      channel_id, name)
    seeded!("raw.channel_dim", "channel_id", channel_id)
  end

  test "a channel we know is named and can be opened" do
    named_channel!("C0APH2MMHH7", "ask")
    in_channel!("C0APH2MMHH7")
    sign_in_as(@me)

    get fd_audit_path
    assert_select %(a[href="/channels/C0APH2MMHH7"]), text: "#ask"
    assert_no_match(/channel C0APH2MMHH7/, response.body)
  end

  test "a channel we do not have is called private and is not a link" do
    in_channel!("C0PRIVATE01")
    sign_in_as(@me)

    get fd_audit_path
    assert_select %(a[href*="C0PRIVATE01"]), false
    assert_match "#private-channel", response.body
  end

  test "a firefighter gets the page, but never the fire engine's own record" do
    engine!(verb: "resolved")
    slack!
    AccessLog.record!(actor: @me, subject_user_id: WHO, field_class: "identity")
    sign_in_as(hold_role!("UFF", "firefighter"))

    get fd_audit_path(view: "everything")
    assert_response :success
    assert_select ".audit-verb", text: "resolved", count: 0
    assert_select ".audit-verb", text: "user login"
  end

  test "the fire engine tabs are not offered to a firefighter" do
    sign_in_as(hold_role!("UFF", "firefighter"))

    get fd_audit_path
    assert_select ".view", text: /Slack/
    assert_select ".view", text: /Fire Engine/, count: 0
    assert_select ".view", text: /Refusals/, count: 0
  end

  test "asking for the fire engine tab by hand does not hand it over" do
    engine!(verb: "resolved")
    them = hold_role!("UFF", "firefighter")
    asked = Fd::AuditQuery.new({ "view" => "engine" }, actor: them)

    assert_equal "slack", asked.view
    assert_empty asked.rows
    assert_empty Fd::AuditQuery.new({ "q" => "source:engine" }, actor: them).rows
  end

  test "a firefighter cannot open the panel for a fire engine event" do
    entry = engine!(verb: "resolved")
    sign_in_as(hold_role!("UFF", "firefighter"))

    get fd_audit_event_path(source: "fire_engine", id: entry.id.to_s)
    assert_response :forbidden
  end

  test "a community manager still sees the whole record" do
    engine!(verb: "resolved")
    slack!
    sign_in_as(@me)

    get fd_audit_path(view: "everything")
    assert_select ".audit-verb", text: "resolved"
    assert_select ".view", text: /Fire Engine/
  end

  test "counting never drags the payload columns through the cap" do
    query = Fd::AuditQuery.new({}, actor: @me)

    [query.send(:count_sql), query.send(:counting_sql)].each do |sql|
      assert_match(/SELECT source FROM \(/, sql,
        "a count only needs the source, and detoasting jsonb for 10k rows is what timed out")
      assert_no_match(/SELECT \* FROM \(SELECT/, sql)
    end
  end

  test "the total is capped per branch, like the view counts" do
    query = Fd::AuditQuery.new({}, actor: @me)

    assert_match(/LIMIT #{Fd::AuditQuery::COUNT_CEILING + 1}\)/, query.send(:count_sql))
  end
end
