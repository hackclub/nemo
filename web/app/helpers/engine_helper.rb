module EngineHelper
  STATUS_CHIP = {
    "ok" => "chip chip-good",
    "failed" => "chip chip-crit",
    "partial" => "chip chip-warn",
    "cancelled" => "chip chip-warn",
    "running" => "chip chip-off",
    "abandoned" => "chip chip-off"
  }.freeze

  STALE_AFTER = 36.hours

  def run_status(row)
    tag.span row.status, class: STATUS_CHIP.fetch(row.status, "chip chip-off")
  end

  def short_age(at)
    return "n/a" if at.nil?

    seconds = (Time.current - at).to_i
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600
    return "#{seconds / 3600}h" if seconds < 86_400

    "#{seconds / 86_400}d"
  end

  FAULT_CHIP = {
    "transport" => "chip-warn", "throttle" => "chip-warn", "auth" => "chip-crit",
    "upstream" => "chip-crit", "contract" => "chip-crit", "cancelled" => "chip-off",
    "local" => "chip-crit", "entity" => "chip-off"
  }.freeze

  def fault_class_chip(error_class)
    FAULT_CHIP.fetch(error_class.to_s, "chip-off")
  end

  def queue_eta(queue)
    return "idle" if queue.pending.to_i.zero?
    return "n/a" if queue.eta_minutes.nil?

    minutes = queue.eta_minutes.to_f
    return "#{minutes.round} min" if minutes < 90
    return "#{(minutes / 60).round(1)} h" if minutes < 48 * 60

    "#{(minutes / 1440).round(1)} d"
  end

  SLICE_CELL = { "complete" => "on", "superseded" => "on", "unavailable" => "un",
                 "short" => "sh", "claimed" => "sh", "missing" => "no" }.freeze

  def slice_cell(state)
    SLICE_CELL.fetch(state, "no")
  end

  UNIT_COST = {
    "search.messages" => "one admin search per member",
    "conversations.replies" => "one admin call per thread",
    "conversations.history" => "one admin call per page of 999 messages",
    "conversations.members" => "one bot call per member",
    "admin.analytics.getMemberAnalytics" => "one internal call per 500 members",
    "admin.analytics.getChannelAnalytics" => "37 internal calls per month",
    "admin.analytics.getFile" => "one internal download per day",
    "admin.users.list" => "one admin call per 100 members",
    "team.stats.timeSeries" => "one internal call per window"
  }.freeze

  def unit_cost(source, name)
    per = UNIT_COST[source.endpoint]
    return "n/a" if per.nil?

    "#{name} of #{Engine::Setting.value(source.key, name)}, #{per}"
  end

  def run_status_tally(statuses)
    counted = statuses.values.sum > 1
    chips = statuses.map do |status, count|
      tag.span(counted ? "#{count} #{status}" : status,
        class: STATUS_CHIP.fetch(status, "chip chip-off"))
    end
    safe_join(chips, " ")
  end

  def worker_state(beat)
    return tag.span("failed", class: "chip chip-crit") if beat.note.to_s.start_with?("FAILED")
    return tag.span("silent", class: "chip chip-warn") if beat.cold?

    tag.span("ok", class: "chip chip-good")
  end

  def worker_note(beats)
    cold = beats.count(&:cold?)
    said = "#{pluralize(beats.size, 'worker')} reporting"
    return said if cold.zero?

    "#{said} · #{cold} silent"
  end

  def worker_chip(worker)
    return tag.span("orphaned, no worker heartbeat", class: "chip chip-crit") if worker.nil?

    tag.span("orphaned, worker cold #{short_age(worker.beat_at)}", class: "chip chip-crit")
  end

  def step_progress(steps)
    last = steps.last
    return nil if last.nil?

    "step #{last.step_index} of #{last.step_total || steps.size}"
  end

  def run_stale?(row)
    Time.current - row.age_from > STALE_AFTER
  end

  def run_age(row)
    age = "#{time_ago_in_words(row.age_from)} ago"
    return tag.span(age, class: "delta-note") unless run_stale?(row)

    tag.span("#{age}, the nightly should run daily", class: "chip chip-warn")
  end

  def output_size(text)
    bytes = text.to_s.bytesize
    return "#{bytes} B" if bytes < 1024

    format("%.1f kB", bytes / 1024.0)
  end

  def run_duration(row)
    seconds = row.seconds
    return "n/a" if seconds.nil?
    return "#{seconds}s" if seconds < 90

    minutes = seconds / 60
    return "#{minutes} min" if minutes < 90

    format("%.1f h", minutes / 60.0)
  end

  def run_rows(row)
    return "n/a" if row.rows_in.nil?

    counted = number_with_delimiter(row.rows_in)
    return counted if row.total_expected.blank?

    "#{counted} of #{number_with_delimiter(row.total_expected)}"
  end
end
