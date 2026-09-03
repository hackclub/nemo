module Appearance
  Theme = Struct.new(:key, :label, :band, :swatch, keyword_init: true)

  THEMES = [
    Theme.new(key: "paper", label: "Paper", band: "light",
      swatch: ["oklch(96.5% 0.005 85)", "oklch(100% 0 0)", "oklch(22.77% 0.008 70)"]),
    Theme.new(key: "latte", label: "Catppuccin Latte", band: "light",
      swatch: ["#e6e9ef", "#eff1f5", "#4c4f69"]),
    Theme.new(key: "solarized-light", label: "Solarized Light", band: "light",
      swatch: ["#eee8d5", "#fdf6e3", "#073642"]),
    Theme.new(key: "dawn", label: "Rosé Pine Dawn", band: "light",
      swatch: ["#faf4ed", "#fffaf3", "#575279"]),
    Theme.new(key: "github-light", label: "GitHub Light", band: "light",
      swatch: ["#f6f8fa", "#ffffff", "#1f2328"]),
    Theme.new(key: "ash", label: "Ash", band: "dark",
      swatch: ["oklch(15.5% 0.006 40)", "oklch(19.8% 0.008 40)", "oklch(92.35% 0.008 55)"]),
    Theme.new(key: "dracula", label: "Dracula", band: "dark",
      swatch: ["#21222c", "#282a36", "#f8f8f2"]),
    Theme.new(key: "mocha", label: "Catppuccin Mocha", band: "dark",
      swatch: ["#181825", "#1e1e2e", "#cdd6f4"]),
    Theme.new(key: "nord", label: "Nord", band: "dark",
      swatch: ["#2e3440", "#3b4252", "#eceff4"]),
    Theme.new(key: "tokyo-night", label: "Tokyo Night", band: "dark",
      swatch: ["#16161e", "#1a1b26", "#c0caf5"]),
    Theme.new(key: "gruvbox", label: "Gruvbox", band: "dark",
      swatch: ["#1d2021", "#282828", "#ebdbb2"]),
    Theme.new(key: "one-dark", label: "One Dark", band: "dark",
      swatch: ["#21252b", "#282c34", "#dcdfe4"]),
    Theme.new(key: "rose-pine", label: "Rosé Pine", band: "dark",
      swatch: ["#191724", "#1f1d2e", "#e0def4"]),
    Theme.new(key: "github-dark", label: "GitHub Dark", band: "dark",
      swatch: ["#0d1117", "#161b22", "#e6edf3"]),
    Theme.new(key: "contrast", label: "Contrast", band: "dark",
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
