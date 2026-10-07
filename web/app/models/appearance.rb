module Appearance
  Theme = Struct.new(:key, :label, :swatch, keyword_init: true)

  THEMES = [
    Theme.new(key: "light", label: "Light",
      swatch: ["oklch(98.5% 0 0)", "oklch(100% 0 0)", "oklch(20.5% 0 0)"]),
    Theme.new(key: "lightsout", label: "Dark",
      swatch: ["oklch(14.5% 0 0)", "oklch(20.5% 0 0)", "oklch(92.2% 0 0)"])
  ].freeze

  KEYS = THEMES.map(&:key).freeze
  RETIRED = %w[dark].freeze
  DEFAULT_LIGHT = "light".freeze
  DEFAULT_DARK = "lightsout".freeze
  ACCENT = "orange".freeze
end
