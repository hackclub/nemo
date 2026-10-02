class Docs
  Section = Struct.new(:id, :title, keyword_init: true)
  Topic = Struct.new(:slug, :title, :group, :sections, keyword_init: true)

  CHANNEL_MANAGERS = Topic.new(
    slug: "channel-managers",
    title: "Channel managers",
    group: "Public API",
    sections: [
      Section.new(id: "access", title: "Access"),
      Section.new(id: "auth", title: "Authentication"),
      Section.new(id: "check", title: "Check a member"),
      Section.new(id: "consent", title: "Consent states"),
      Section.new(id: "rate", title: "Rate limits"),
      Section.new(id: "errors", title: "Errors")
    ]
  )

  ALL = [CHANNEL_MANAGERS].freeze

  def self.topics = ALL

  def self.groups = ALL.group_by(&:group)

  def self.first = ALL.first

  def self.find(slug) = ALL.find { |topic| topic.slug == slug.to_s }

  def self.section_ids = ALL.flat_map { |topic| topic.sections.map(&:id) }
end
