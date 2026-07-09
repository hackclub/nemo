bootstrap_id = ENV["BOOTSTRAP_ADMIN_SLACK_ID"]

if bootstrap_id.present?
  staff = Staff.find_or_initialize_by(user_id: bootstrap_id)
  staff.community_manager = true
  staff.save!
  puts "seeded community_manager: #{bootstrap_id}"
else
  puts "BOOTSTRAP_ADMIN_SLACK_ID not set, skipping staff seed"
end
