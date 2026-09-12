module ApplicationHelper
  def open_case_count
    @open_case_count ||= Fd::Case.unresolved.count
  end

  def held_label(staff)
    return Fd::Access::MANAGER_LABEL if Fd::Access.manager?(staff)
    return "no access" if staff.nil?

    roles = Authz.roles_held(staff.user_id)
    return "no access" if roles.empty?

    roles.map { |role| Authz.role_label(role) }.to_sentence
  end

  def on?(key)
    Fd::Flag.on?(key)
  end

  def engine_running?
    return @engine_running unless @engine_running.nil?

    @engine_running = SyncRequest.active.exists?
  rescue StandardError
    @engine_running = false
  end

  JOURNEY = [
    ["Joining", "joining"],
    ["Getting replies", "replies"],
    ["Coming back", "returning"],
    ["Who is active", "active"]
  ].freeze

  ACTIONS = {
    "joining" => "acquisition",
    "replies" => "replies", "returning" => "retention",
    "active" => "distribution"
  }.freeze

  MOVED = {
    "acquisition" => "joining",
    "response" => "replies", "retention" => "returning",
    "distribution" => "active"
  }.freeze

  def journey_stages
    JOURNEY
  end

  NAV_ICONS = {
    "overview" => ["M3 3h7v7H3z", "M14 3h7v7h-7z", "M14 14h7v7h-7z", "M3 14h7v7H3z"],
    "joining" => ["M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4", "M10 17l5-5-5-5", "M15 12H3"],
    "newcomers" => ["M17 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2", "M9.5 3a4 4 0 1 1 0 8 4 4 0 0 1 0-8",
                    "M19 3v4", "M21 5h-4"],
    "replies" => ["M21 15a2 2 0 0 1-2 2H8l-4 4V5a2 2 0 0 1 2-2h13a2 2 0 0 1 2 2z"],
    "returning" => ["M3 12a9 9 0 0 1 15-6.7L21 8", "M21 3v5h-5",
                    "M21 12a9 9 0 0 1-15 6.7L3 16", "M3 21v-5h5"],
    "active" => ["M3 12h4l3 8 4-16 3 8h4"],
    "channels" => ["M5 9h14", "M5 15h14", "M10 3 8 21", "M16 3l-2 18"],
    "engine" => ["M20 14a8 8 0 1 0-16 0", "m15 10-3.4 3.4"],
    "runs" => ["M20 14a8 8 0 1 0-16 0", "m15 10-3.4 3.4"],
    "sources" => ["M12 3c4.4 0 8 1.3 8 3s-3.6 3-8 3-8-1.3-8-3 3.6-3 8-3",
                  "M4 6v6c0 1.7 3.6 3 8 3s8-1.3 8-3V6", "M4 12v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"],
    "coverage" => ["M3 4h7v7H3z", "M14 4h7v7h-7z", "M3 15h7v5H3z", "M14 15h7v5h-7z"],
    "queues" => ["M4 6h16", "M4 12h11", "M4 18h6"],
    "backfill" => ["M12 21V7", "m6 13 6 6 6-6", "M5 3h14"],
    "archive" => ["M3 7h18v4H3z", "M5 11v8a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-8", "M10 15h4"],
    "faults" => ["M12 4 3 19h18L12 4Z", "M12 10v4", "M12 17v.01"],
    "tuning" => ["M5 21V10", "M12 21V4", "M19 21v-7", "M3 10h4", "M10 4h4", "M17 14h4"],
    "people" => ["M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2", "M9 3a4 4 0 1 1 0 8 4 4 0 0 1 0-8",
                 "M22 21v-2a4 4 0 0 0-3-3.87"],
    "roles" => ["M12 3 4 6v6c0 5 8 10 8 10s8-5 8-10V6z"],
    "flags" => ["M6 3v18", "M6 4h11l-2 4 2 4H6"],
    "group" => ["M4 7h16", "M4 12h16", "M4 17h10"]
  }.freeze

  SIDEBAR_MIN = 200
  SIDEBAR_MAX = 460

  def sidebar_class
    "sidebar-icon" if cookies[:sidebar] == "icon"
  end

  def sidebar_style
    width = cookies[:sidebarw].to_i
    return nil unless width.between?(SIDEBAR_MIN, SIDEBAR_MAX)

    "--sidebar-w: #{width}px"
  end

  def nav_icon(key)
    paths = NAV_ICONS.fetch(key.to_s, NAV_ICONS.fetch("group"))
    tag.svg(class: "ic", width: 15, height: 15, viewBox: "0 0 24 24", fill: "none",
      stroke: "currentColor", "stroke-width": 1.7, "stroke-linecap": "round",
      "stroke-linejoin": "round", "aria-hidden": "true") do
      safe_join(paths.map { |d| tag.path(d: d) })
    end
  end

  CACHET_FACES = "https://cachet.hackclub.com/users".freeze

  def cachet_face_url(user_id)
    "#{CACHET_FACES}/#{ERB::Util.url_encode(user_id)}/r"
  end

  def section_pane
    return "layouts/admin_pane" if page_section == "admin"
    return nil unless on?(:analytics)
    return "layouts/engine_pane" if controller_name == "engine"
    return "layouts/community_pane" if %w[home journey channels].include?(controller_name)

    nil
  end
end
