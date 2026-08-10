class Deployment
  Marker = Struct.new(:mode, :seeded_at, :profile, :scale, :rng, keyword_init: true) do
    def seeded?
      mode == "seeded"
    end
  end

  CACHE_KEY = "deployment/marker".freeze
  CACHE_TTL = 5.minutes

  def self.current
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { read }
  end

  def self.seeded?
    current.seeded?
  end

  def self.read
    row = ActiveRecord::Base.connection.select_one(
      "SELECT mode, seeded_at, seed_profile, seed_scale, seed_rng FROM analytics.dim_deployment"
    )
    return live unless row

    Marker.new(
      mode: row["mode"],
      seeded_at: row["seeded_at"],
      profile: row["seed_profile"],
      scale: row["seed_scale"],
      rng: row["seed_rng"]
    )
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn("deployment marker unreadable, assuming live: #{e.message}")
    live
  end

  def self.live
    Marker.new(mode: "live")
  end
end
