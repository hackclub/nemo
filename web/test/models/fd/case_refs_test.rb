require "test_helper"

class Fd::CaseRefsTest < ActiveSupport::TestCase
  test "ids finds three to six digit references once each" do
    assert_equal [1234, 5633], Fd::CaseRefs.ids("see #1234 and (#5633), #1234 again")
  end

  test "ids ignores short numbers and numbers glued to words" do
    assert_empty Fd::CaseRefs.ids("we're #1 and #12, abc#1234 #1234abc ##1234 path/#1234 #1234567")
  end

  test "linked links an existing case and leaves other numbers as text" do
    kase = make_case
    missing = Fd::Case.maximum(:id) + 1000

    html = Fd::CaseRefs.linked("see ##{kase.id} and ##{missing} <b>")

    assert_includes html, %(<a class="lnk" href="/fd/cases/#{kase.id}">##{kase.id}</a>)
    assert_includes html, "##{missing}"
    assert_not_includes html, %(href="/fd/cases/#{missing}")
    assert_includes html, "&lt;b&gt;"
    assert html.html_safe?
  end

  test "linked without references only escapes" do
    assert_equal "a &amp; b", Fd::CaseRefs.linked("a & b")
  end
end
