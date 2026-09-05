module Appearance
  Theme = Struct.new(:key, :label, :band, :swatch, keyword_init: true)

  THEMES = [
    Theme.new(key: "light", label: "Light", band: "light",
      swatch: ["oklch(96.6% 0.005 253)", "oklch(99.3% 0.003 253)", "oklch(22.5% 0.020 253)"]),
    Theme.new(key: "dark", label: "Dark", band: "dark",
      swatch: ["oklch(18.2% 0.006 75)", "oklch(22.2% 0.007 75)", "oklch(94.5% 0.008 82)"]),
    Theme.new(key: "contrast", label: "Contrast", band: "dark",
      swatch: ["oklch(0% 0 0)", "oklch(14% 0 0)", "oklch(100% 0 0)"])
  ].freeze

  BANDS = { "light" => "Light", "dark" => "Dark" }.freeze
  KEYS = THEMES.map(&:key).freeze
  BAND_OF = THEMES.to_h { |theme| [theme.key, theme.band] }.freeze
  DEFAULT_LIGHT = "light".freeze
  DEFAULT_DARK = "dark".freeze

  def self.find(key)
    THEMES.find { |theme| theme.key == key }
  end

  def self.of_band(band)
    THEMES.select { |theme| theme.band == band }
  end
end
