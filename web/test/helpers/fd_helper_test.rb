require "test_helper"

class FdHelperTest < ActionView::TestCase
  include FdHelper

  def kase(**attrs)
    make_case(opened_at: 5.days.ago, **attrs)
  end

  def entries(count)
    Array.new(count) { Fd::CaseTimeline::Entry.new(at: Time.current, title: "x") }
  end

  test "an open case says how old it is and who has it" do
    line = timeline_standing(make_case(opened_at: 5.days.ago, assign: "UFF2"), entries(3))
    assert_equal "Still open. 5d, assigned to @UFF2.", line
  end

  test "an unassigned case says so rather than naming nobody" do
    assert_match(/still unassigned/, timeline_standing(kase, entries(2)))
  end

  test "a resolved case states its outcome" do
    line = timeline_standing(
      kase(resolved_at: Time.utc(2026, 3, 4, 12), resolution: "action_taken"), entries(6)
    )
    assert_equal "Resolved 4 Mar as action taken.", line
  end

  test "an empty timeline says nothing has happened" do
    assert_equal "Nothing has happened on this case yet.", timeline_standing(kase, [])
  end

  test "one subject reads as a handle" do
    assert_equal "@UAAA", subject_handles(make_case(subject: "UAAA"))
  end

  test "several subjects name the first and count the rest" do
    saved = make_case(subject: "UAAA")
    saved.add_subject!("UBBB")
    assert_equal "@UAAA and 1 other", subject_handles(Fd::Case.find(saved.id))

    saved.add_subject!("UCCC")
    assert_equal "@UAAA and 2 others", subject_handles(Fd::Case.find(saved.id))
  end

  test "a case about nobody says so rather than naming an empty handle" do
    assert_equal "no subject set", subject_handles(make_case(subject: nil))
  end

  test "a blank category is n/a, not a bare key" do
    assert_equal "n/a", category_short(nil)
    assert_equal "n/a", category_short("")
  end

  test "a category key reads with spaces, not underscores" do
    assert_equal "harassment general", category_short("harassment_general")
  end

  test "zero priors reads as never reported, not zero" do
    assert_equal "never reported before", prior_phrase(0)
    assert_equal "chip-good", prior_tone(0)
  end

  test "one prior is singular" do
    assert_equal "1 prior", prior_phrase(1)
    assert_equal "chip-off", prior_tone(1)
  end

  test "two or more priors are plural and read as a warning" do
    assert_equal "2 priors", prior_phrase(2)
    assert_equal "chip-crit", prior_tone(2)
    assert_equal "5 priors", prior_phrase(5)
  end

  test "a case with one subject shows their prior count" do
    saved = make_case(subject: "UAAA")
    chip = prior_chip(Fd::Case.find(saved.id), { "UAAA" => 3 })
    assert_match(/3 priors/, chip)
  end

  test "a subject missing from the prior count reads as never reported" do
    saved = make_case(subject: "UAAA")
    chip = prior_chip(Fd::Case.find(saved.id), {})
    assert_match(/never reported before/, chip)
  end

  test "a case with no single subject has no prior chip to show" do
    saved = make_case(subject: "UAAA")
    saved.add_subject!("UBBB")
    assert_equal "n/a", prior_chip(Fd::Case.find(saved.id), { "UAAA" => 4 })
  end

  test "the row subtitle folds the category in front of the subject" do
    saved = make_case(subject: "UAAA", category_key: "spam")
    line = row_subtitle(Fd::Case.find(saved.id), {})
    assert_match(/\Aspam/, line)
  end

  test "a blank category does not leave a stray n/a in the subtitle" do
    saved = make_case(subject: "UAAA")
    line = row_subtitle(Fd::Case.find(saved.id), {})
    assert_no_match(/n\/a/, line)
  end

  test "several subjects are counted" do
    saved = make_case(subject: "UAAA")
    saved.add_subject!("UBBB")
    line = row_subtitle(Fd::Case.find(saved.id), {})
    assert_match(/2 subjects/, line)
  end

  test "no subject yet says so plainly, not as a bare n/a" do
    saved = make_case(subject: nil)
    line = row_subtitle(Fd::Case.find(saved.id), {})
    assert_match(/subject not yet identified/, line)
  end

  test "a case with thread messages counts them in the subtitle" do
    saved = make_case(subject: "UAAA")
    line = row_subtitle(Fd::Case.find(saved.id), { saved.id => 8 })
    assert_match(/8 messages/, line)
  end

  test "a case with no thread messages does not print a zero" do
    saved = make_case(subject: "UAAA")
    line = row_subtitle(Fd::Case.find(saved.id), {})
    assert_no_match(/0 messages/, line)
  end

  test "the row names the reporter, not the subject, when a report is on file" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, reporter_user_id: "UREP", is_anonymous: false,
      source_app: "shroud", received_at: Time.current)
    assert_equal "@UREP", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "an anonymous report reads as anonymous, not by the missing name" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, is_anonymous: true,
      source_app: "shroud", received_at: Time.current)
    assert_equal "anonymous", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "a case with no report at all names who opened it directly" do
    saved = make_case(subject: "UAAA", opened_by: "UOPEN")
    assert_equal "@UOPEN", row_reporter_label(Fd::Case.find(saved.id))
  end

  test "several reports name the first reporter and count the rest" do
    saved = make_case(subject: "UAAA")
    Fd::CaseReport.create!(case_id: saved.id, reporter_user_id: "UREP1", is_anonymous: false,
      source_app: "shroud", received_at: Time.current)
    Fd::CaseReport.create!(case_id: saved.id, reporter_user_id: "UREP2", is_anonymous: false,
      source_app: "shroud", received_at: Time.current)
    assert_equal "@UREP1 and 1 other", row_reporter_label(Fd::Case.find(saved.id))
  end
end
