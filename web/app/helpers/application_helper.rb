module ApplicationHelper
  def open_case_count
    @open_case_count ||= Fd::Case.unresolved.count
  end

  def on?(key)
    Fd::Flag.on?(key)
  end

  THEMES = [
    ["system", "System", ["#f7f7f9", "#131318", "#6c4ef5"]],
    ["paper", "Paper", ["#f7f7f9", "#ffffff", "#6c4ef5"]],
    ["fog", "Fog", ["#f4f6f9", "#ffffff", "#1f6fd0"]],
    ["slate", "Slate", ["#131318", "#1a1a21", "#9b84ff"]],
    ["midnight", "Midnight", ["#08090c", "#0e1014", "#4fd1c5"]],
    ["ember", "Ember", ["#16130f", "#1d1a15", "#e8934a"]]
  ].freeze

  def theme_options
    THEMES
  end
end
