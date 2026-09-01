module Appearance
  Theme = Struct.new(:key, :label, :band, :note, :swatch, keyword_init: true)

  THEMES = [
    Theme.new(key: "paper", label: "Paper", band: "light", note: nil,
      swatch: ["oklch(96.5% 0.005 85)", "oklch(100% 0 0)", "oklch(22.77% 0.008 70)"]),
    Theme.new(key: "chalk", label: "Chalk", band: "light", note: nil,
      swatch: ["oklch(95.1% 0.024 248)", "oklch(99.5% 0.0025 248)", "oklch(25.57% 0.03 252)"]),
    Theme.new(key: "sepia", label: "Sepia", band: "light", note: nil,
      swatch: ["oklch(94.3% 0.048 88)", "oklch(97.2% 0.0328 88)", "oklch(25.6% 0.042 68)"]),
    Theme.new(key: "ash", label: "Ash", band: "dark", note: nil,
      swatch: ["oklch(15.5% 0.006 40)", "oklch(19.8% 0.008 40)", "oklch(92.35% 0.008 55)"]),
    Theme.new(key: "slate", label: "Slate", band: "dark", note: nil,
      swatch: ["oklch(16.8% 0.0464 248)", "oklch(21.2% 0.056 248)", "oklch(92.77% 0.036 245)"]),
    Theme.new(key: "moss", label: "Moss", band: "dark", note: nil,
      swatch: ["oklch(15.8% 0.0356 162)", "oklch(20% 0.044 162)", "oklch(92.26% 0.032 150)"]),
    Theme.new(key: "dim", label: "Dim", band: "dark", note: nil,
      swatch: ["oklch(8.5% 0.005 42)", "oklch(13% 0.006 42)", "oklch(90.19% 0.008 58)"]),
    Theme.new(key: "void", label: "Void", band: "dark", note: "amoled",
      swatch: ["oklch(0% 0 0)", "oklch(4% 0.003 50)", "oklch(90.91% 0.005 75)"]),
    Theme.new(key: "contrast", label: "Contrast", band: "dark", note: "a11y",
      swatch: ["oklch(0% 0 0)", "oklch(46% 0 0)", "oklch(92.83% 0 0)"])
  ].freeze

  BANDS = { "light" => "Light", "dark" => "Dark" }.freeze
  KEYS = THEMES.map(&:key).freeze
  BAND_OF = THEMES.to_h { |theme| [theme.key, theme.band] }.freeze
  DEFAULT_LIGHT = "paper".freeze
  DEFAULT_DARK = "ash".freeze

  def self.find(key)
    THEMES.find { |theme| theme.key == key }
  end

  def self.of_band(band)
    THEMES.select { |theme| theme.band == band }
  end
end
