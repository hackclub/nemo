require "test_helper"

class Fd::ChatVersionTest < ActiveSupport::TestCase
  setup { @kase = make_case }

  def said(body = "on it")
    Fd::CaseChat.create!(case_id: @kase.id, author_user_id: "UME", body: body,
      source_app: "fire_engine")
  end

  test "an empty case still has a version to compare against" do
    assert_equal "0.0-0.0-0.0", Fd::ChatVersion.for(@kase.id)
  end

  test "a new message moves the version" do
    before = Fd::ChatVersion.for(@kase.id)
    said
    assert_not_equal before, Fd::ChatVersion.for(@kase.id)
  end

  test "a deleted message moves it too, so the reload is not skipped" do
    row = said
    before = Fd::ChatVersion.for(@kase.id)
    row.destroy!
    assert_not_equal before, Fd::ChatVersion.for(@kase.id)
  end

  test "housekeeping columns the trigger fires on leave it alone" do
    row = said
    before = Fd::ChatVersion.for(@kase.id)
    row.update_columns(last_seen_at: 1.minute.from_now)
    assert_equal before, Fd::ChatVersion.for(@kase.id)
  end
end
