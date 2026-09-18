module YouHelper
  def figure(value)
    return tag.span("n/a", class: "sub2") if value.nil?

    number_with_delimiter(value)
  end

  def you_span_label(key)
    return "All time" if key == "all"

    "Last #{You::Profile::SPANS.fetch(key)[:label]}"
  end

  def you_here(profile, **overrides)
    here = {
      span: (profile.span_key unless profile.custom? ||
              profile.span_key == You::Profile::DEFAULT_SPAN),
      start: (profile.window_start.iso8601 if profile.custom?),
      end: (profile.window_end.iso8601 if profile.custom?),
      streak: (profile.streak_basis unless
                profile.streak_basis == You::Profile::DEFAULT_BASIS)
    }
    you_path(**here.merge(overrides).compact)
  end

  def you_range_label(profile)
    return window_note(profile.window_start, profile.window_end) if profile.custom?

    you_span_label(profile.span_key)
  end

  def calendar_cell_class(cell)
    css = ["cal-cell", "h#{cell.step}"]
    css << "is-before" if cell.before?
    css << "is-future" if cell.future?
    css
  end

  def calendar_tip(cell)
    return nil unless cell.measured?

    {
      title: cell.on.strftime("%a %-d %b %Y"),
      rows: calendar_tip_rows(cell),
      note: (cell.on == Date.current ? "today" : nil)
    }.compact
  end

  def calendar_tip_rows(cell)
    return [{ label: "nothing posted", value: "0" }] if cell.messages.zero?

    [
      { label: "messages", value: number_with_delimiter(cell.messages) },
      { label: "channels", value: number_with_delimiter(cell.channels) },
      { label: "replies", value: number_with_delimiter(cell.replies) }
    ]
  end

  def calendar_note(calendar)
    said = ["#{number_with_delimiter(calendar.active_days)} active days"]
    said << "busiest #{number_with_delimiter(calendar.peak)} on " \
            "#{calendar.cells.max_by(&:messages).on.strftime('%-d %b')}" if calendar.peak.positive?
    said.join(" · ")
  end

  def streak_line(streak)
    return "no streak yet" if streak.nil? || !streak.running?

    said = ["since #{streak.current_from.strftime('%-d %b %Y')}"]
    said.unshift("##{number_with_delimiter(streak.streak_rank)} of " \
                 "#{number_with_delimiter(streak.streak_of)}") if streak.streak_rank
    said.join(" · ")
  end

  def longest_line(streak)
    return nil if streak&.longest_days.nil?

    "longest #{number_with_delimiter(streak.longest_days)} days, " \
      "#{streak.longest_from.strftime('%b %Y')}"
  end

  def last_posted(at)
    return tag.span("n/a", class: "sub2") if at.nil?

    on = at.to_date
    days = (Date.current - on).to_i
    return "today" if days <= 0
    return "yesterday" if days == 1
    return "#{days} days ago" if days < 14
    return "#{days / 7} weeks ago" if days < 70

    on.strftime("%-d %b %Y")
  end

  def platform_line(profile)
    parts = { days_ios: "iOS", days_desktop: "desktop", days_android: "Android" }
      .filter_map do |key, label|
        share = profile.platform_share(key)
        next nil if share.nil? || share.zero?

        "#{label} #{share}%"
      end
    parts.any? ? parts.join(" · ") : "no platform reported"
  end
end
