ids = ENV["BOOTSTRAP_ADMIN_SLACK_ID"].to_s.split(",").map(&:strip).reject(&:empty?).uniq

if ids.empty?
  puts "BOOTSTRAP_ADMIN_SLACK_ID not set, skipping the first grant"
else
  ids.each do |user_id|
    Staff.find_or_create_by!(user_id: user_id)
    held = Authz::Grant.live.for_person(user_id).roles.pluck(:name)
    if held.include?(Fd::Access::MANAGER_ROLE)
      puts "confirmed #{Fd::Access::MANAGER_ROLE}: #{user_id}"
      next
    end

    Authz::Grant.give!(user_id, kind: "role", name: Fd::Access::MANAGER_ROLE,
      by: "seed", reason: "bootstrap admin")
    puts "granted #{Fd::Access::MANAGER_ROLE}: #{user_id}"
  end
  puts "managers now: #{Authz.who_holds('access.grant').sort.join(', ')}"
end
