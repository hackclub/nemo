require "test_helper"

class FdAuditPagingTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
    @base = Time.zone.parse("2026-10-01 12:00")
    @ids = (1..250).map do |minute|
      id = SecureRandom.uuid
      as_pipeline(<<~SQL.squish, id, @base - minute.minutes)
        INSERT INTO slack.audit_event (id, at, action, category, actor_kind, actor_id, ours, payload, source_key)
        VALUES (?::uuid, ?, 'user_login', 'sign_ins', 'user', 'UPAGE', false, '{}', 'test')
      SQL
      seeded!("slack.audit_event", "id", id)
      id
    end
  end

  def page(params = {})
    Fd::AuditQuery.new({ "view" => "slack" }.merge(params), actor: @me)
  end

  test "back walks newer from the first row and lands on the same page next came from" do
    first = page
    assert_nil first.back_params
    second = page(first.next_params)
    third = page(second.next_params)

    back = page(third.back_params)
    assert_equal second.rows.map(&:id), back.rows.map(&:id)
    assert page(back.back_params).rows.map(&:id) == first.rows.map(&:id)
  end

  test "the first page reached by going back has nowhere further back to go" do
    first = page
    second = page(first.next_params)
    back = page(second.back_params)

    assert_equal first.rows.map(&:id), back.rows.map(&:id)
    assert_nil back.back_params
  end

  test "going to a date shows the newest events up to the end of that day" do
    jumped = page("on" => "2026-10-01")
    assert_equal @ids.first(100), jumped.rows.map(&:id)

    assert_empty page("on" => "2026-09-30").rows, "a day before every event holds none of them"
  end

  test "the page bar carries back, next and the date to go to" do
    get fd_audit_path(view: "slack")
    assert_select ".pagebar span.is-off", "Back"
    assert_select ".pagebar a", "Next"
    assert_select ".pagebar [data-controller='datepicker'][data-datepicker-submit-value='true'] input[name='on']"

    get fd_audit_path(page.next_params)
    assert_select ".pagebar a", "Back"
  end
end
