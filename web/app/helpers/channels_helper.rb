module ChannelsHelper
  def channel_sort_th(label, column, css = nil)
    active = @sort == column
    next_direction = active ? (@direction == "asc" ? "desc" : "asc") : "desc"
    arrow = active ? (@direction == "asc" ? " &uarr;" : " &darr;") : ""
    sort_state = active ? (@direction == "asc" ? "ascending" : "descending") : "none"

    tag.th(class: css, **{ "aria-sort": sort_state }) do
      link_to safe_join([label, arrow.html_safe]),
        channels_path(sort: column, direction: next_direction, q: @q.presence),
        class: "sortable"
    end
  end
end
