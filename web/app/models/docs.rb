class Docs
  Section = Struct.new(:id, :title, keyword_init: true)
  Topic = Struct.new(:slug, :title, :blurb, :sections, keyword_init: true)

  CHANNEL_MANAGERS = Topic.new(
    slug: "channel-managers",
    title: "Channel manager API",
    blurb: "Resolves whether a member holds the channel manager role on a public channel. " \
           "Gated on that member's consent. Returns nothing else about them.",
    sections: [
      Section.new(id: "auth", title: "Authentication"),
      Section.new(id: "check", title: "Check a member"),
      Section.new(id: "consent", title: "Consent states"),
      Section.new(id: "rate", title: "Rate limits"),
      Section.new(id: "errors", title: "Errors")
    ]
  )

  ALL = [CHANNEL_MANAGERS].freeze

  def self.topics = ALL

  def self.section_ids = ALL.flat_map { |topic| topic.sections.map(&:id) }
end
