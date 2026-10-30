require "test_helper"

class FdMergesTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    @main = make_case
    @dup_one = make_case
    @dup_two = make_case
  end

  def merge(ids, target, **params)
    post fd_merge_cases_path,
      params: { case_ids: Array(ids).map(&:to_s), duplicate_of: target.to_s }.merge(params)
  end

  test "merge signed out redirects to login and resolves nothing" do
    merge([@dup_one.id], @main.id)
    assert_redirected_to login_path
    assert_nil @dup_one.reload.resolved_at
  end

  test "merge marks cases duplicate of the target and keeps the target open" do
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    [@dup_one, @dup_two].each do |kase|
      kase.reload
      assert_equal "duplicate", kase.resolution
      assert_equal @main.id, kase.duplicate_of
      assert_not_nil kase.resolved_at
    end

    assert_nil @main.reload.resolved_at, "the main case must stay open"
    assert_match(/2 cases marked duplicate of case #{@main.id}/, flash[:notice])
  end

  test "merge keeps threads and participants on the duplicate and adds no thread to the target" do
    Fd::CaseThread.create!(case_id: @dup_one.id, channel_id: "C1", thread_ts: "1.1",
      is_primary: true, added_by: "UFF1")
    Fd::CaseParticipant.create!(case_id: @dup_one.id, user_id: "UINV", role: "subject")

    sign_in_as(@me)
    merge([@dup_one.id], @main.id)

    assert_equal 1, @dup_one.reload.threads.count
    assert_equal %w[subject subject], @dup_one.participants.map(&:role).sort
    assert_equal 0, @main.reload.threads.count
  end

  test "merge copies duplicate assignees to target" do
    @main.assign!("UKEEP")
    @dup_one.assign!("UKEEP")
    @dup_one.assign!("UONE")
    @dup_two.assign!("UTWO")
    sign_in_as(@me)

    merge([@dup_one.id, @dup_two.id], @main.id)

    assert_equal %w[UKEEP UONE UTWO], @main.reload.assignee_user_ids.sort
    entries = Fd::AuditEntry.where(entity_type: "assignee", entity_id: @main.id, verb: "attached")
    assert_equal %w[UONE UTWO], entries.map { |entry| entry.after["user_id"] }.sort
    assert_equal [@dup_one.id, @dup_two.id], entries.first.after["source_case_ids"].sort
  end

  test "merge ignores the target when it is also in case_ids" do
    sign_in_as(@me)
    merge([@main.id, @dup_one.id], @main.id)

    assert_nil @main.reload.resolved_at
    assert_equal "duplicate", @dup_one.reload.resolution
    assert_match(/1 case marked duplicate/, flash[:notice])
  end

  test "merge into a duplicate target sets duplicate_of to the original case" do
    @main.update!(resolved_at: 1.hour.ago, resolution: "duplicate", duplicate_of: @dup_two.id)
    sign_in_as(@me)
    merge([@dup_one.id], @main.id)

    assert_equal @dup_two.id, @dup_one.reload.duplicate_of,
      "pointing at a duplicate must resolve to the case it duplicates"
  end

  test "merge skips resolved cases and reports the skipped count" do
    @dup_two.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    assert_equal "no_action", @dup_two.reload.resolution
    assert_match(/1 case marked duplicate of case #{@main.id} · 1 skipped/, flash[:notice])
  end

  test "merge with all cases resolved alerts Cases already resolved" do
    @dup_one.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    @dup_two.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    assert_equal "Cases already resolved", flash[:alert]
  end

  test "merge resolves a case assigned to another user" do
    @dup_one.assign!("UOTHER")
    sign_in_as(@me)
    merge([@dup_one.id], @main.id)

    assert_not_nil @dup_one.reload.resolved_at
    assert_equal @main.id, @dup_one.duplicate_of
  end

  test "merge without duplicate_of keeps the oldest case open as target" do
    @main.update!(opened_at: 9.days.ago)
    sign_in_as(@me)
    post fd_merge_cases_path, params: { case_ids: [@main.id, @dup_one.id, @dup_two.id].map(&:to_s) }

    assert_nil @main.reload.resolved_at, "the oldest must stay open"
    assert_equal @main.id, @dup_one.reload.duplicate_of
    assert_equal @main.id, @dup_two.reload.duplicate_of
  end

  test "merge with one case_id alerts Select at least two cases" do
    sign_in_as(@me)
    post fd_merge_cases_path, params: { case_ids: [@dup_one.id.to_s] }
    assert_nil @dup_one.reload.resolved_at
    assert_match(/Select at least two cases/, flash[:alert])
  end

  test "merge with empty case_ids alerts Select cases" do
    sign_in_as(@me)
    merge([], @main.id)
    assert_match(/Select cases/, flash[:alert])
  end

  test "merge with unknown duplicate_of alerts Case not found" do
    sign_in_as(@me)
    merge([@dup_one.id], 999_999)
    assert_nil @dup_one.reload.resolved_at
    assert_match(/Case not found/, flash[:alert])
  end

  test "merge writes one resolved audit entry per case with a shared request_id" do
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    rows = Fd::AuditEntry.where(entity_type: "case", entity_id: [@dup_one.id, @dup_two.id],
      verb: "resolved")
    assert_equal 2, rows.count
    assert_equal 1, rows.pluck(:request_id).uniq.size
    assert_equal [@main.id, @main.id], rows.map { |r| r.after["duplicate_of"] }
  end

  test "show merge renders candidate groups and multi-select checkboxes" do
    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_response :success
    assert_select ".merge-find.queue-search input.queue-search-input[aria-label='Search cases']", count: 1
    assert_select ".merge-group", minimum: 1
    assert_select "input.tick[type='checkbox'][name='case_ids[]']", minimum: 2
    assert_select "input[type='submit'][disabled]", count: 1
  end

  test "show merge renders the report body of a candidate" do
    body_text = "they kept posting the same link after being asked to stop"
    Fd::CaseReport.create!(case_id: @main.id, is_anonymous: true,
      source_app: "relay", received_at: Time.current, body: body_text)

    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_response :success
    assert_select ".merge-pick .queue-subject", text: /#{Regexp.escape(body_text)}/, minimum: 1
  end

  test "show merge renders No report for a candidate without a report" do
    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_select ".merge-pick .queue-subject", text: /No report/, minimum: 1
  end

  test "show merge renders candidates with queue row id and violation markup" do
    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_select ".merge-pick .queue-row", minimum: 2
    assert_select ".merge-pick .queue-row .queue-top .queue-id", minimum: 2
    assert_select ".merge-pick .queue-row .queue-meta .queue-violation", minimum: 2
  end

  def forwarded_into(kase, body_text:, link: "https://hackclub.slack.com/archives/C0LOUNGE/p1754487721123456")
    report = Fd::CaseReport.create!(case_id: kase.id, reporter_user_id: "UREP1",
      is_anonymous: false, source_app: "relay", received_at: Time.current, body: link)
    conversation = Fd::IntakeConversation.create!(report_id: report.id, channel_id: "D0REP",
      thread_ts: "1.0", opened_at: 1.hour.ago)
    message = Fd::IntakeMessage.create!(conversation_id: conversation.id, channel_id: "D0REP",
      ts: "#{Time.current.to_i}.0001", direction: "inbound", author_user_id: "UREP1",
      body: link, posted_at: 1.hour.ago)
    Fd::IntakeShare.create!(message_id: message.id, kind: "forward", source_channel_id: "C0LOUNGE",
      source_ts: "1754487721.123456", source_author_user_id: "UBAD", source_body: body_text,
      permalink: link, is_reachable: true)
  end

  test "show merge renders the forwarded body for a link only report and hides the url" do
    body_text = "read the room, nobody wants that here"
    forwarded_into(@main, body_text: body_text)

    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_response :success
    assert_select ".merge-pick .queue-cite-body", text: /#{Regexp.escape(body_text)}/, minimum: 1
    assert_select ".merge-pick .queue-cite-how", text: /forwarded/, minimum: 1
    assert_select ".merge-pick .queue-cite-body", { text: /hackclub\.slack\.com/, count: 0 },
      "bare link is not rendered"
  end

  test "show merge renders the typed report body and no forwarded citation" do
    forwarded_into(@main, body_text: "the forwarded words")
    @main.reports.first.update!(body: "what the reporter typed themselves")

    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_select ".merge-pick .queue-subject", text: /what the reporter typed themselves/, minimum: 1
    assert_select ".merge-pick .queue-cite", count: 0
  end

  def make_extra_cases(count)
    count.times { |n| make_case(subject: format("UOTHER%02d", n)) }
  end

  test "show merge limits candidates to PER_PAGE and renders the expand target" do
    make_extra_cases(12)
    sign_in_as(@me)

    get fd_case_merge_path(@dup_one)

    assert_select "#merge-around .merge-pick", count: Fd::MergesController::PER_PAGE
    assert_select ".pane-more[data-expand-into-value='merge-around']", count: 1
  end

  test "show merge page 2 renders distinct candidates and an expand-next template" do
    make_extra_cases(20)
    sign_in_as(@me)

    get fd_case_merge_path(@dup_one)
    first_page = css_select("#merge-around .merge-pick input.tick").map { |tick| tick["value"] }

    get fd_case_merge_path(@dup_one, page: 2)

    assert_response :success
    second_page = css_select(".merge-pick input.tick").map { |tick| tick["value"] }
    assert_equal Fd::MergesController::PER_PAGE, second_page.size
    assert_empty first_page & second_page, "a case must not be offered twice"
    assert_select "template[data-expand-next]", count: 1
  end

  test "show merge past the last page renders no candidates and no expand-next template" do
    sign_in_as(@me)

    get fd_case_merge_path(@dup_one, page: 9)

    assert_response :success
    assert_select "template[data-expand-next]", count: 0
    assert_select ".merge-pick", count: 0
  end

  test "show merge page 2 renders rows without turbo-frame or form" do
    make_extra_cases(12)
    sign_in_as(@me)

    get fd_case_merge_path(@dup_one, page: 2)

    assert_select "turbo-frame", count: 0
    assert_select "form", count: 0
    assert_select ".merge-pick", minimum: 1
  end

  test "show merge queries case_reports at most twice for all candidates" do
    [@main, @dup_two].each do |kase|
      Fd::CaseReport.create!(case_id: kase.id, is_anonymous: true,
        source_app: "relay", received_at: Time.current, body: "a report on #{kase.id}")
    end
    sign_in_as(@me)

    queries = []
    subscriber = ->(*, payload) { queries << payload[:sql] if payload[:sql].to_s.include?("FROM \"fd\".\"case_reports\"") }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get fd_case_merge_path(@dup_one) }

    assert_response :success
    assert_operator queries.size, :<=, 2, "the reports must be preloaded, not read per candidate"
  end

  def stagger_opened_at
    @main.update!(opened_at: 3.days.ago)
    @dup_one.update!(opened_at: 2.days.ago)
    @dup_two.update!(opened_at: 1.day.ago)
  end

  test "confirm merge responds success and resolves no case" do
    stagger_opened_at
    sign_in_as(@me)
    get fd_confirm_merge_cases_path(case_ids: [@dup_two.id, @main.id, @dup_one.id])

    assert_response :success
    assert_equal 0, Fd::Case.where(id: [@main.id, @dup_one.id, @dup_two.id])
      .where.not(resolved_at: nil).count
  end

  test "confirm merge with one case_id redirects to cases with alert" do
    sign_in_as(@me)
    get fd_confirm_merge_cases_path(case_ids: [@main.id])

    assert_redirected_to fd_cases_path
    assert_match(/Select at least two/, flash[:alert])
  end
end
