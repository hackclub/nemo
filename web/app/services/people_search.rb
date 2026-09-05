class PeopleSearch
  MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/i
  MIN_TERM = 2
  LIMIT = 8

  Found = Struct.new(:id, :name, :handle, :initial, :deleted, :source, keyword_init: true)

  def self.call(term, limit: LIMIT)
    new(term.to_s.strip, limit).results
  end

  def initialize(term, limit)
    @term = term
    @limit = limit
  end

  def results
    return [] if @term.length < MIN_TERM

    ids = (by_id + by_name).uniq.first(@limit)
    return [] if ids.empty?

    names = Fd::Names.for(ids)
    ids.map { |id| shown(id, names) }
  end

  private

  def by_id
    return [] unless @term.match?(MEMBER_ID)

    wanted = @term.upcase
    exact = Analytics::DimMember.where(user_id: wanted).pluck(:user_id)
    return exact if exact.any?

    Analytics::DimMember.where("user_id LIKE ?", "#{wanted}%")
      .order(:user_id).limit(@limit).pluck(:user_id)
  end

  def by_name
    Fd::Member.search(@term, limit: @limit).pluck(:user_id)
  end

  def shown(id, names)
    member = names.member(id)
    Found.new(id: id, name: names[id], handle: member&.handle,
      initial: names.initial(id), deleted: member&.is_deleted || false,
      source: member ? "fd" : "workspace")
  end
end
