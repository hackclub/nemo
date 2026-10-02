module DocsHelper
  def doc_anchor(id)
    link_to "##{id}", class: "doc-anchor", aria: { label: "Link to this section" } do
      tag.svg(width: 13, height: 13, viewBox: "0 0 24 24", fill: "none",
        stroke: "currentColor", "stroke-width": 1.8, "stroke-linecap": "round",
        "stroke-linejoin": "round", "aria-hidden": "true") do
        safe_join([
          tag.path(d: "M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"),
          tag.path(d: "M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7")
        ])
      end
    end
  end

  def doc_copy
    tag.button(type: "button", class: "doc-copy", data: { action: "copy#write" },
      aria: { label: "Copy" }) do
      safe_join([
        tag.svg(class: "doc-copy-off", width: 13, height: 13, viewBox: "0 0 24 24",
          fill: "none", stroke: "currentColor", "stroke-width": 1.7,
          "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true") do
          safe_join([
            tag.rect(x: 9, y: 9, width: 11, height: 11, rx: 2),
            tag.path(d: "M5 15V5a2 2 0 0 1 2-2h8")
          ])
        end,
        tag.svg(class: "doc-copy-on", width: 13, height: 13, viewBox: "0 0 24 24",
          fill: "none", stroke: "currentColor", "stroke-width": 2,
          "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true") do
          tag.path(d: "M5 13l4 4L19 7")
        end
      ])
    end
  end
end
