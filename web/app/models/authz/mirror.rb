class Authz
  module Mirror
    ROLE_FOR = { "firefighter" => "firefighter", "lead" => "firefighter",
                 "community_manager" => "community_manager" }.freeze

    CAPABILITIES_FOR = {
      ["read", "observer"] => [],
      ["read", "analyst"] => %w[member.read],
      ["read", "curator"] => %w[member.read],
      ["ops", "operator"] => %w[engine.read engine.stage channel.backfill],
      ["ops", "steward"] => %w[engine.read engine.stage channel.backfill
                               engine.sync engine.tune]
    }.freeze

    BY = "mirror".freeze

    class << self
      def role!(user_id, role, by: BY)
        want = ROLE_FOR[role.to_s]
        return if want.nil?

        Grant.give!(user_id, kind: "role", name: want, by: by || BY,
          reason: "mirrored from the old grant tables")
      end

      def drop_role!(user_id, by: BY)
        Grant.live.for_person(user_id).roles.find_each { |held| held.take_back!(by: by || BY) }
      end

      def community!(user_id, family, role, by: BY)
        return role!(user_id, "community_manager", by: by) if curator?(family, role)

        (CAPABILITIES_FOR[[family.to_s, role.to_s]] || []).each do |name|
          Grant.give!(user_id, kind: "capability", name: name, by: by || BY,
            reason: "mirrored from community role #{role}")
        end
      end

      def drop_community!(user_id, family, role, by: BY)
        return drop_role!(user_id, by: by) if curator?(family, role)

        names = CAPABILITIES_FOR[[family.to_s, role.to_s]] || []
        Grant.live.for_person(user_id).capabilities.where(name: names)
          .find_each { |held| held.take_back!(by: by || BY) }
      end

      def curator?(family, role)
        family.to_s == "read" && role.to_s == "curator"
      end

      def manager!(user_id, by: BY)
        role!(user_id, "community_manager", by: by)
      end

      def drop_manager!(user_id, by: BY)
        Grant.live.for_person(user_id).roles.where(name: "community_manager")
          .find_each { |held| held.take_back!(by: by || BY) }
      end

      def override!(role, key, allowed, by: BY)
        want = ROLE_FOR[role.to_s]
        return if want.nil? || !Authz.keys.include?(key.to_s)

        Override.upsert({ role: want, capability: key.to_s, allowed: allowed,
                          changed_by: by || BY, changed_at: Time.current },
          unique_by: %i[role capability])
      end

      def forget_overrides!(pairs)
        pairs.each do |role, key|
          want = ROLE_FOR[role.to_s]
          next if want.nil?

          Override.where(role: want, capability: key.to_s).delete_all
        end
      end
    end
  end
end
