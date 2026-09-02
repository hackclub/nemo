class Panel
  class Unknown < ArgumentError; end

  PATH = Rails.root.join("../db/panels.yml").freeze
  ALL = YAML.load_file(PATH).fetch("panels").freeze

  def self.keys = ALL.keys

  def self.fetch(key)
    ALL.fetch(key.to_s) { raise Unknown, "#{key} is not a panel" }
  end

  def self.label(key) = fetch(key).fetch("label")

  def self.needs(key) = fetch(key)["needs"]

  def self.open?(key) = needs(key).nil?

  def self.visible?(key, account)
    want = needs(key)
    return account.present? if want.nil?

    Authz.may?(account, want)
  end

  def self.visible_to(account)
    keys.select { |key| visible?(key, account) }
  end
end
