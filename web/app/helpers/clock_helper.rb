module ClockHelper
  def clock_note(clock)
    said = [window_note(clock.window_start, clock.window_end)]
    said << "#{number_with_delimiter(clock.total)} messages"
    said << clock_coverage(clock)
    said.compact.join(" · ")
  end

  def clock_coverage(clock)
    held = share_pct(clock.total, clock.covered)
    return nil if held.nil?

    across = if clock.channels.to_i > 1
      " across #{number_with_delimiter(clock.channels)} channels"
    end
    "#{number_to_percentage(held, precision: 1)} of what was posted#{across}"
  end

  def clock_tip(cell, clock)
    {
      title: "#{cell.day} at #{format('%02d:00', cell.hour)} UTC",
      rows: [
        { label: "messages", value: number_with_delimiter(cell.messages), tone: cell.tone },
        { label: "of the busiest hour",
          value: number_to_percentage((cell.share * 100).round(1), precision: 1) }
      ],
      note: clock_peak_note(cell, clock)
    }.compact
  end

  def clock_peak_note(cell, clock)
    top = clock.busiest
    return nil if top.nil? || (top.day == cell.day && top.hour == cell.hour)

    "busiest is #{top.day} at #{format('%02d:00', top.hour)}"
  end
end
