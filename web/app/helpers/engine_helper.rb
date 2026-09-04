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

  SOURCE_STATE_CLASS = { "stale" => "state-stale", "never run" => "state-never" }.freeze

  def source_state_class(state)
    SOURCE_STATE_CLASS.fetch(state, "state-live")
  end

  def short_age(at)
    return "n/a" if at.nil?

    seconds = (Time.current - at).to_i
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600
    return "#{seconds / 3600}h" if seconds < 86_400

    "#{seconds / 86_400}d"
  end

  def short_seconds(seconds)
    return "n/a" if seconds.nil?

    seconds = seconds.round
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m #{seconds % 60}s" if seconds < 3600

    "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
  end

  def run_status_tally(statuses)
    counted = statuses.values.sum > 1
    chips = statuses.map do |status, count|
      tag.span(counted ? "#{count} #{status}" : status,
        class: STATUS_CHIP.fetch(status, "chip chip-off"))
    end
    safe_join(chips, " ")
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
