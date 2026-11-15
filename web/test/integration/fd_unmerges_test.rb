require "test_helper"

class FdUnmergesTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    sign_in_as(@me)
    @main = make_case(opened_at: 9.days.ago)
    @dup = make_case(opened_at: 5.days.ago)
  end

  def merge(ids, target)
    post fd_merge_cases_path, params: { case_ids: Array(ids).map(&:to_s), duplicate_of: target.to_s }
  end

  def unmerge(kase, back: nil)
    post fd_case_unmerge_path(kase), params: { back: back }.compact
  end

  def tag!(name) = Fd::Tag.create!(name: name, created_by: "UME")

  def tag_case!(kase, tag) = Fd::CaseTag.create!(case_id: kase.id, tag_id: tag.id, added_by: "UME")

  def live_merge(kase) = Fd::CaseMerge.live.find_by(case_id: kase.id)

  def report_on(kase, at:, ts:)
    Fd::CaseReport.create!(case_id: kase.id, is_anonymous: true, body: "report on #{kase.id}",
      source_app: "relay", received_at: at, card_channel_id: "C0FIRE", forwarded_ts: ts)
  end

  def without_resolve!
    firefighter = grant_role!("UFIRE", "firefighter")
    override_capability!("firefighter", "case.resolve", false)
    sign_in_as(firefighter)
  end

  test "merge records each case's status from before the merge" do
    @dup.update!(resolved_at: 3.days.ago, resolution: "no_action")
    other = make_case
    merge([@dup.id, other.id], @main.id)

    assert_equal "no_action", live_merge(@dup).prior_resolution
    assert_nil live_merge(other).prior_resolution
    assert_equal @main.id, live_merge(other).into_case_id
  end

  test "merge copies tags with the merge that brought them" do
    spam = tag!("spam")
    tag_case!(@dup, spam)
    merge([@dup.id], @main.id)

    assert_equal live_merge(@dup).id, Fd::CaseTag.find_by!(case_id: @main.id, tag_id: spam.id).merge_id
  end

  test "a case moved to another case keeps its status from before the first merge" do
    @dup.update!(resolved_at: 3.days.ago, resolution: "no_action")
    @dup.update!(resolution: "duplicate", duplicate_of: @main.id)
    other = make_case
    @dup.update!(duplicate_of: other.id)

    assert_equal other.id, live_merge(@dup).into_case_id
    assert_equal "no_action", live_merge(@dup).prior_resolution
    assert_equal 2, Fd::CaseMerge.where(case_id: @dup.id).count
  end

  test "unmerge of a case open before the merge reopens it and its reports" do
    report = report_on(@dup, at: 4.days.ago, ts: "1700000000.000100")
    merge([@dup.id], @main.id)
    report.update!(closed_at: 1.hour.ago, closed_by: "UME")

    unmerge(@dup, back: @main.id)

    assert_redirected_to fd_case_path(@main)
    assert_equal "Case #{@dup.id} unmerged from case #{@main.id}", flash[:notice]
    @dup.reload
    assert_nil @dup.duplicate_of
    assert_nil @dup.resolved_at
    assert_nil report.reload.closed_at
    assert_nil live_merge(@dup)
    assert_not_nil Fd::CaseMerge.find_by!(case_id: @dup.id).unmerged_at
    entry = Fd::AuditEntry.find_by!(entity_type: "case", entity_id: @dup.id, verb: "unmerged")
    assert_equal @main.id, entry.before["duplicate_of"]
  end

  test "unmerge of a case resolved before the merge keeps its resolution" do
    resolved_at = 3.days.ago.change(usec: 0)
    @dup.update!(resolved_at: resolved_at, resolution: "no_action")
    merge([@dup.id], @main.id)

    unmerge(@dup)

    assert_redirected_to fd_case_path(@dup)
    @dup.reload
    assert_nil @dup.duplicate_of
    assert_equal "no_action", @dup.resolution
    assert_equal resolved_at, @dup.resolved_at
  end

  test "merging a case that has merged cases puts them all on the main case" do
    child = make_case
    merge([child.id], @dup.id)
    merge([@dup.id], @main.id)

    assert_equal @main.id, child.reload.duplicate_of
    assert_equal @main.id, live_merge(child).into_case_id
    assert_equal [@dup.id, child.id].sort, @main.reload.merged_in.map(&:id).sort
  end

  test "a moved case's tags go with it to the main case" do
    alt = tag!("alt-account")
    child = make_case
    tag_case!(child, alt)
    merge([child.id], @dup.id)
    merge([@dup.id], @main.id)

    assert_not Fd::CaseTag.exists?(case_id: @dup.id, tag_id: alt.id)
    assert_equal live_merge(child).id, Fd::CaseTag.find_by!(case_id: @main.id, tag_id: alt.id).merge_id
  end

  test "unmerge takes out only that case" do
    child = make_case
    merge([child.id], @dup.id)
    merge([@dup.id], @main.id)

    unmerge(@dup)

    assert_nil @dup.reload.duplicate_of
    assert_equal @main.id, child.reload.duplicate_of
  end

  test "unmerge removes tags only that case brought and keeps tags another merged case has" do
    spam = tag!("spam")
    scam = tag!("scam")
    own = tag!("own")
    other = make_case
    tag_case!(@dup, spam)
    tag_case!(@dup, scam)
    tag_case!(other, scam)
    tag_case!(@main, own)
    merge([@dup.id, other.id], @main.id)

    unmerge(@dup)

    assert_equal %w[own scam], @main.reload.tags.map(&:name).sort
    assert_equal live_merge(other).id, Fd::CaseTag.find_by!(case_id: @main.id, tag_id: scam.id).merge_id
    entry = Fd::AuditEntry.find_by!(entity_type: "case_tag", entity_id: @main.id, verb: "removed")
    assert_equal ["spam"], entry.before["tags"]
  end

  test "unmerge of a case that is not merged alerts" do
    unmerge(@dup)

    assert_equal "Case #{@dup.id} is not merged", flash[:alert]
  end

  test "unmerge without case.resolve changes nothing" do
    merge([@dup.id], @main.id)
    without_resolve!

    unmerge(@dup)

    assert_equal @main.id, @dup.reload.duplicate_of
  end

  test "reopen of a merged case unmerges it and opens it" do
    @dup.update!(resolved_at: 3.days.ago, resolution: "no_action")
    merge([@dup.id], @main.id)

    delete fd_case_resolution_path(@dup)

    @dup.reload
    assert_nil @dup.duplicate_of
    assert_nil @dup.resolved_at
    assert Fd::AuditEntry.exists?(entity_type: "case", entity_id: @dup.id, verb: "unmerged")
    assert Fd::AuditEntry.exists?(entity_type: "case", entity_id: @dup.id, verb: "reopened")
  end

  test "merged case page names its main case and offers Unmerge with no Reopen" do
    merge([@dup.id], @main.id)

    get fd_case_path(@dup)

    assert_select ".warnbar", count: 0
    assert_select ".merge-strip", count: 0
    assert_select ".closed-what", text: /merged into case #{@main.id}/
    assert_select ".closed-what a[href=?]", fd_case_path(@main), text: "case #{@main.id}"
    assert_select ".closed button.closed-do[data-modal-open=?]", "unmerge-#{@dup.id}", text: "Unmerge"
    assert_select ".menu-pop button[data-modal-open=?]", "unmerge-#{@dup.id}", text: /Unmerge/
    assert_select "form[action=?]", fd_case_resolution_path(@dup), count: 0
    assert_select ".modal-title", text: "Unmerge case #{@dup.id} from case #{@main.id}?"
    assert_select "form[action=?] input[name=back][value=?]", fd_case_unmerge_path(@dup), @dup.id.to_s
    assert_select "form[action=?] input.btn-crit[value=Unmerge]", fd_case_unmerge_path(@dup)
  end

  test "primary thread list offers Unmerge on merged case threads only" do
    cases = Array.new(4) { make_case }
    report_on(@main, at: 9.days.ago, ts: "1700000000.000100")
    cases.each_with_index { |kase, index| report_on(kase, at: (8 - index).days.ago, ts: "1700000000.00020#{index}") }
    merge(cases.map(&:id), @main.id)

    get fd_case_path(@main, tab: "report")

    assert_select ".thread-pop .thread-item", 5
    assert_select ".thread-pop .thread-unmerge", 4
    cases.each { |kase| assert_select ".thread-unmerge[data-modal-open=?]", "unmerge-#{kase.id}" }
    assert_select ".modal-title", text: "Unmerge case #{cases.first.id} from case #{@main.id}?"
  end

  test "main case page names itself the main case and lists its merged cases" do
    other = make_case
    merge([other.id, @dup.id], @main.id)

    get fd_case_path(@main)

    assert_select ".merge-strip .closed-what", text: /Main case · 2 merged cases:/
    [@dup, other].each { |kase| assert_select ".merge-strip a[href=?]", fd_case_path(kase), text: kase.id.to_s }
  end

  test "thread list puts the main case first and labels merged case threads" do
    cases = Array.new(3) { make_case }
    cases.each_with_index { |kase, index| report_on(kase, at: (9 - index).days.ago, ts: "1700000000.00020#{index}") }
    report_on(@main, at: 1.day.ago, ts: "1700000000.000100")
    merge(cases.map(&:id), @main.id)

    get fd_case_path(@main, tab: "report")

    labels = css_select(".thread-pop .thread-row .thread-meta > span:first-child").map { |span| span.text.strip }
    assert_equal ["Main case #{@main.id}", *cases.map { |kase| "Merged case #{kase.id}" }], labels
  end

  test "with three threads or fewer the open merged thread shows Unmerge in its header" do
    main_report = report_on(@main, at: 9.days.ago, ts: "1700000000.000100")
    dup_report = report_on(@dup, at: 8.days.ago, ts: "1700000000.000200")
    merge([@dup.id], @main.id)

    get fd_case_path(@main, tab: "report", thread: dup_report.id)
    assert_select ".chat-head button[data-modal-open=?]", "unmerge-#{@dup.id}", text: "Unmerge"

    get fd_case_path(@main, tab: "report", thread: main_report.id)
    assert_select ".chat-head button[data-modal-open]", count: 0
  end

  test "thread list hides Unmerge without case.resolve" do
    cases = Array.new(4) { make_case }
    report_on(@main, at: 9.days.ago, ts: "1700000000.000100")
    cases.each_with_index { |kase, index| report_on(kase, at: (8 - index).days.ago, ts: "1700000000.00020#{index}") }
    merge(cases.map(&:id), @main.id)
    without_resolve!

    get fd_case_path(@main, tab: "report")

    assert_select ".thread-unmerge", count: 0
    assert_select "[data-modal-id-value^=unmerge-]", count: 0
  end
end
