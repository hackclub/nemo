ids = ENV["BOOTSTRAP_ADMIN_SLACK_ID"].to_s.split(",").map(&:strip).reject(&:empty?).uniq

if ids.empty?
  puts "BOOTSTRAP_ADMIN_SLACK_ID not set, skipping staff seed"
else
  ids.each do |user_id|
    staff = Staff.find_or_initialize_by(user_id: user_id)
    was_new = staff.new_record?
    staff.community_manager = true
    staff.save!
    puts "#{was_new ? 'added' : 'confirmed'} community_manager: #{user_id}"
  end
  puts "staff list now: #{Staff.where(community_manager: true).pluck(:user_id).sort.join(', ')}"
end
