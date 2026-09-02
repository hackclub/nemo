require "test_helper"

module Fd
  class PermissionGateTest < ActiveSupport::TestCase
    ME = "UME".freeze
    THEM = "UTHEM".freeze

    CHECKS = YAML.load_file(Rails.root.join("../db/permission_checks.yml"))
      .fetch("checks").freeze

    setup do
      @by = Staff.create!(user_id: "UBOSS", community_manager: true)
    end

    def staff_holding(role, manager: false)
      if manager
        staff = Staff.find_or_create_by!(user_id: ME)
        staff.update!(community_manager: true)
        return staff.tap { Current.forget_roles }
      end
      return Staff.new(user_id: ME) if role.nil?

      staff = Staff.find_or_create_by!(user_id: ME)
      AccessGrant.give!(ME, role: role, by: @by.user_id, reason: "for the gate test")
      staff.tap { Current.forget_roles }
    end

    def case_for(kind)
      case kind
      when "free" then make_case
      when "mine" then make_case(assign: ME)
      when "theirs" then make_case(assign: THEM)
      end
    end

    def move(key, moved)
      moved.to_h.each { |role, allowed| RolePermission.set!(role, key, allowed, by: @by.user_id) }
    end

    test "every check in the shared file agrees" do
      wrong = CHECKS.filter_map do |check|
        AccessGrant.where(user_id: ME).delete_all
        RolePermission.delete_all
        Staff.where(user_id: ME).update_all(community_manager: false)
        Current.forget_roles

        staff = staff_holding(check["role"], manager: check["manager"] == true)
        move(check["key"], check["moved"])
        record = case_for(check["case"])

        got = Access.allow?(staff, check["key"], record)
        next if got == check["allowed"]

        "#{check['name']}: got #{got}, wanted #{check['allowed']}"
      end

      assert_empty wrong, wrong.join("\n")
    end

    test "the file covers every scoped permission, so a new scope cannot slip in unchecked" do
      scoped = Permission.keys.select { |key| Permission.scope(key) == :assigned }
      checked = CHECKS.filter_map { |check| check["key"] if check["case"] == "theirs" }.uniq

      assert_equal [], scoped - checked,
        "add a check for these to db/permission_checks.yml"
    end

    test "a refusal says why, in words the bot can say too" do
      staff = staff_holding("lead")

      assert_equal "give or take back access is community manager only",
        Access.why_not(staff, "access.grant")
    end
  end
end
