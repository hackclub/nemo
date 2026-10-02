require "test_helper"

class FdMergesTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    @main = make_case
    @dup_one = make_case
    @dup_two = make_case
  end

  def merge(ids, target, **params)
    post fd_merge_cases_path,
      params: { case_ids: Array(ids).map(&:to_s), duplicate_of: target.to_s }.merge(params)
  end

  test "a signed out visitor cannot merge anything" do
    merge([@dup_one.id], @main.id)
    assert_redirected_to login_path
    assert_nil @dup_one.reload.resolved_at
  end

  test "several cases close as duplicates of one main case" do
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    [@dup_one, @dup_two].each do |kase|
      kase.reload
      assert_equal "duplicate", kase.resolution
      assert_equal @main.id, kase.duplicate_of
      assert_not_nil kase.resolved_at
    end

    assert_nil @main.reload.resolved_at, "the main case must stay open"
    assert_match(/2 cases closed as duplicates of case #{@main.id}, which stays open/, flash[:notice])
  end

  test "each duplicate keeps its own threads and people" do
    Fd::CaseThread.create!(case_id: @dup_one.id, channel_id: "C1", thread_ts: "1.1",
      is_primary: true, added_by: "UFF1")
    Fd::CaseParticipant.create!(case_id: @dup_one.id, user_id: "UINV", role: "subject")

    sign_in_as(@me)
    merge([@dup_one.id], @main.id)

    assert_equal 1, @dup_one.reload.threads.count
    assert_equal %w[subject subject], @dup_one.participants.map(&:role).sort
    assert_equal 0, @main.reload.threads.count
  end

  test "the main case is ignored even if it is ticked too" do
    sign_in_as(@me)
    merge([@main.id, @dup_one.id], @main.id)

    assert_nil @main.reload.resolved_at
    assert_equal "duplicate", @dup_one.reload.resolution
    assert_match(/1 case closed as duplicate/, flash[:notice])
  end

  test "a chain of duplicates collapses to the original" do
    @main.update!(resolved_at: 1.hour.ago, resolution: "duplicate", duplicate_of: @dup_two.id)
    sign_in_as(@me)
    merge([@dup_one.id], @main.id)

    assert_equal @dup_two.id, @dup_one.reload.duplicate_of,
      "pointing at a duplicate must resolve to the case it duplicates"
  end

  test "already resolved cases are left alone and counted" do
    @dup_two.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    assert_equal "no_action", @dup_two.reload.resolution
    assert_match(/1 case closed as duplicate of case #{@main.id}, which stays open, 1 left alone/, flash[:notice])
  end

  test "every ticked case being resolved already says only that" do
    @dup_one.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    @dup_two.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    assert_equal "nothing to mark: those cases are resolved already", flash[:alert]
  end

  test "a case assigned to somebody else still merges" do
    @dup_one.assign!("UOTHER")
    sign_in_as(@me)
    merge([@dup_one.id], @main.id)

    assert_not_nil @dup_one.reload.resolved_at
    assert_equal @main.id, @dup_one.duplicate_of
  end

  test "with no case named, the oldest of the ticked ones stays open" do
    @main.update!(opened_at: 9.days.ago)
    sign_in_as(@me)
    post fd_merge_cases_path, params: { case_ids: [@main.id, @dup_one.id, @dup_two.id].map(&:to_s) }

    assert_nil @main.reload.resolved_at, "the oldest must stay open"
    assert_equal @main.id, @dup_one.reload.duplicate_of
    assert_equal @main.id, @dup_two.reload.duplicate_of
  end

  test "ticking a single case explains that duplicates need two" do
    sign_in_as(@me)
    post fd_merge_cases_path, params: { case_ids: [@dup_one.id.to_s] }
    assert_nil @dup_one.reload.resolved_at
    assert_match(/tick at least two cases/, flash[:alert])
  end

  test "merging with nothing ticked is refused" do
    sign_in_as(@me)
    merge([], @main.id)
    assert_match(/tick the cases/, flash[:alert])
  end

  test "a named case that does not exist is refused" do
    sign_in_as(@me)
    merge([@dup_one.id], 999_999)
    assert_nil @dup_one.reload.resolved_at
    assert_match(/nothing to keep/, flash[:alert])
  end

  test "every duplicate writes its own trail entry under one request" do
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    rows = Fd::AuditEntry.where(entity_type: "case", entity_id: [@dup_one.id, @dup_two.id],
      verb: "resolved")
    assert_equal 2, rows.count
    assert_equal 1, rows.pluck(:request_id).uniq.size
    assert_equal [@main.id, @main.id], rows.map { |r| r.after["duplicate_of"] }
  end

  test "the merge body groups candidates and allows selecting several" do
    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_response :success
    assert_select ".merge-find.qsearch input.qsearch-in[aria-label='Search cases']", count: 1
    assert_select ".merge-group", minimum: 1
    assert_select "input.tick[type='checkbox'][name='case_ids[]']", minimum: 2
    assert_select "input[type='submit'][disabled]", count: 1
  end

  test "a candidate shows what its report said, not only who and when" do
    said = "they kept posting the same link after being asked to stop"
    Fd::CaseReport.create!(case_id: @main.id, is_anonymous: true,
      source_app: "shroud", received_at: Time.current, body: said)

    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_response :success
    assert_select ".merge-pick .qsubj", text: /#{Regexp.escape(said)}/, minimum: 1
  end

  test "a candidate with no report says so rather than showing nothing" do
    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_select ".merge-pick .qsubj", text: /no report on file/, minimum: 1
  end

  test "a candidate reads like the same case does in the queue" do
    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_select ".merge-pick .qrow", minimum: 2
    assert_select ".merge-pick .qrow .qtop .qid", minimum: 2
    assert_select ".merge-pick .qrow .qmeta .qviol", minimum: 2
  end

  def forwarded_into(kase, said:, link: "https://hackclub.slack.com/archives/C0LOUNGE/p1754487721123456")
    report = Fd::CaseReport.create!(case_id: kase.id, reporter_user_id: "UREP1",
      is_anonymous: false, source_app: "shroud", received_at: Time.current, body: link)
    conversation = Fd::IntakeConversation.create!(report_id: report.id, channel_id: "D0REP",
      thread_ts: "1.0", opened_at: 1.hour.ago)
    message = Fd::IntakeMessage.create!(conversation_id: conversation.id, channel_id: "D0REP",
      ts: "#{Time.current.to_i}.0001", direction: "inbound", author_user_id: "UREP1",
      body: link, posted_at: 1.hour.ago)
    Fd::IntakeShare.create!(message_id: message.id, kind: "forward", source_channel_id: "C0LOUNGE",
      source_ts: "1754487721.123456", source_author_user_id: "UBAD", source_body: said,
      permalink: link, is_reachable: true)
  end

  test "a report that is only a link shows what was forwarded, not the url" do
    said = "read the room, nobody wants that here"
    forwarded_into(@main, said: said)

    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_response :success
    assert_select ".merge-pick .qcite-said", text: /#{Regexp.escape(said)}/, minimum: 1
    assert_select ".merge-pick .qcite-how", text: /forwarded/, minimum: 1
    assert_select ".merge-pick .qcite-said", { text: /hackclub\.slack\.com/, count: 0 },
      "the bare link is what we replaced, so it must not show"
  end

  test "words of their own outrank anything they also forwarded" do
    forwarded_into(@main, said: "the forwarded words")
    @main.reports.first.update!(body: "what the reporter typed themselves")

    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_select ".merge-pick .qsubj", text: /what the reporter typed themselves/, minimum: 1
    assert_select ".merge-pick .qcite", count: 0
  end

  def others(count)
    count.times { |n| make_case(subject: format("UOTHER%02d", n)) }
  end

  test "the list stops at a page and offers to fetch the next" do
    others(12)
    sign_in_as(@me)

    get fd_case_merge_path(@dup_one)

    assert_select "#merge-around .merge-pick", count: Fd::MergesController::PER_PAGE
    assert_select ".pane-more[data-more-into-value='merge-around']", count: 1
  end

  test "scrolling on fetches the next page and says whether more follow" do
    others(20)
    sign_in_as(@me)

    get fd_case_merge_path(@dup_one)
    first = css_select("#merge-around .merge-pick input.tick").map { |tick| tick["value"] }

    get fd_case_merge_path(@dup_one, page: 2)

    assert_response :success
    next_lot = css_select(".merge-pick input.tick").map { |tick| tick["value"] }
    assert_equal Fd::MergesController::PER_PAGE, next_lot.size
    assert_empty first & next_lot, "a case must not be offered twice"
    assert_select "template[data-more-next]", count: 1
  end

  test "the last page offers nothing further" do
    sign_in_as(@me)

    get fd_case_merge_path(@dup_one, page: 9)

    assert_response :success
    assert_select "template[data-more-next]", count: 0
    assert_select ".merge-pick", count: 0
  end

  test "a later page carries only the rows, not the whole modal" do
    others(12)
    sign_in_as(@me)

    get fd_case_merge_path(@dup_one, page: 2)

    assert_select "turbo-frame", count: 0
    assert_select "form", count: 0
    assert_select ".merge-pick", minimum: 1
  end

  test "reading the candidates' reports does not query once per candidate" do
    [@main, @dup_two].each do |kase|
      Fd::CaseReport.create!(case_id: kase.id, is_anonymous: true,
        source_app: "shroud", received_at: Time.current, body: "a report on #{kase.id}")
    end
    sign_in_as(@me)

    asked = []
    listen = ->(*, payload) { asked << payload[:sql] if payload[:sql].to_s.include?("FROM \"fd\".\"case_reports\"") }
    ActiveSupport::Notifications.subscribed(listen, "sql.active_record") { get fd_case_merge_path(@dup_one) }

    assert_response :success
    assert_operator asked.size, :<=, 2, "the reports must be preloaded, not read per candidate"
  end

  def in_order
    @main.update!(opened_at: 3.days.ago)
    @dup_one.update!(opened_at: 2.days.ago)
    @dup_two.update!(opened_at: 1.day.ago)
  end

  test "the confirmation names every ticked case and merges nothing yet" do
    in_order
    sign_in_as(@me)
    get fd_confirm_merge_cases_path(case_ids: [@dup_two.id, @main.id, @dup_one.id])

    assert_response :success
    assert_equal 0, Fd::Case.where(id: [@main.id, @dup_one.id, @dup_two.id])
      .where.not(resolved_at: nil).count
  end

  test "confirming with one case ticked is refused" do
    sign_in_as(@me)
    get fd_confirm_merge_cases_path(case_ids: [@main.id])

    assert_redirected_to fd_cases_path
    assert_match(/tick at least two/, flash[:alert])
  end
end
