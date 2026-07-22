module ChannelsHelper
  def channel_sort_link(label, column)
    active = @sort == column
    next_direction = active && @direction == "asc" ? "desc" : "asc"
    arrow = active ? (@direction == "asc" ? " &uarr;" : " &darr;") : ""

    link_to safe_join([label, arrow.html_safe]), channels_path(sort: column, direction: next_direction), class: "mn-eyebrow"
  end
end
