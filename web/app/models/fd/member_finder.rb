module Fd
  class MemberFinder
    MENTION = /<@([UW][A-Z0-9]+)(?:\|[^>]*)?>/i
    LINK = %r{\Ahttps?://\S*/([UW][A-Z0-9]{8,})(?:[/?#]\S*)?\z}
    BARE_ID = /\A[UW](?=[A-Z0-9]*\d)[A-Z0-9]{6,12}\z/i
    EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
    WORDS = 5
    TRIGRAM = 3
    FUZZY_FROM = 4
    CLOSE_ENOUGH = 0.35
    NOTHING = "SELECT NULL::text AS user_id WHERE false".freeze
    SEEN_EXACT = 0
    HIDDEN_EXACT = 1
    SEEN_PHRASE = 2
    SEEN_START = 3
    HIDDEN_START = 4
    SEEN_WITHIN = 5
    HIDDEN_WITHIN = 6
    SPELLED_CLOSE = 7

    Found = Struct.new(:ids, :total)

    def initialize(term, actor: nil)
      @typed = term.to_s.strip.delete_prefix("@")
      @identity = actor.present? && actor.may?(RosterSql::IDENTITY_READ)
    end

    def user_id
      return @user_id if defined?(@user_id)

      pasted = MENTION.match(@typed) || LINK.match(@typed)
      @user_id = pasted ? pasted[1].upcase : (@typed.upcase if BARE_ID.match?(@typed))
    end

    def email
      return @email if defined?(@email)

      @email = @identity && EMAIL.match?(@typed) ? @typed.downcase : nil
    end

    def words
      @words ||= @typed.downcase.split(/[\s,]+/).reject(&:empty?).uniq.first(WORDS)
    end

    def find(limit:, offset: 0)
      return Found.new([], 0) if user_id.nil? && words.empty?

      rows = ApplicationRecord.connection.select_all(sql(limit, offset)).to_a
      Found.new(rows.map { |row| row["user_id"] }, rows.first ? rows.first["found"].to_i : 0)
    end

    def pick(limit:, case_id: nil, bots: false, everyone: false)
      return [] if user_id.nil? && (words.empty? || @typed.length < Member::MIN_TERM)

      ApplicationRecord.connection.select_values(
        pick_sql(limit, case_id: case_id, bots: bots, everyone: everyone)
      )
    end

    def sql(limit, offset = 0)
      user_id ? by_id(limit, offset) : by_name(limit, offset)
    end

    def pick_sql(limit, case_id: nil, bots: false, everyone: false)
      return ApplicationRecord.sanitize_sql_array(["SELECT user_id FROM fd.member WHERE user_id = ?", user_id]) if user_id

      picked(limit, case_id, everyone ? "true" : "NOT m.is_deleted AND #{'NOT ' unless bots}m.is_bot")
    end

    private

    def by_id(limit, offset)
      ApplicationRecord.sanitize_sql_array([<<~SQL, { id: user_id, limit: limit, offset: offset }])
        SELECT user_id, count(*) OVER () AS found FROM (#{holding(':id')}) asked
        LIMIT :limit OFFSET :offset
      SQL
    end

    def holding(id)
      "SELECT user_id FROM fd.member WHERE user_id = #{id} " \
        "UNION SELECT user_id FROM fd.case_participants WHERE user_id = #{id} " \
        "UNION SELECT target_user_id FROM fd.actions WHERE target_user_id = #{id} " \
        "UNION SELECT subject_user_id FROM fd.notes WHERE subject_user_id = #{id}"
    end

    def by_name(limit, offset)
      ApplicationRecord.sanitize_sql_array([<<~SQL, binds.merge(limit: limit, offset: offset)])
        WITH #{ranked(holding(':upper'), 'NOT m.is_bot')},
        touched AS (
          SELECT user_id FROM fd.case_participants
          UNION SELECT target_user_id FROM fd.actions WHERE target_user_id IS NOT NULL
          UNION SELECT subject_user_id FROM fd.notes
          WHERE subject_user_id IS NOT NULL AND deleted_at IS NULL
        )
        SELECT k.user_id, count(*) OVER () AS found
        FROM kept k
        LEFT JOIN touched t ON t.user_id = k.user_id
        LEFT JOIN analytics.fct_member_window w
          ON w.source = :lifetime AND w.user_id = k.user_id
        WHERE NOT k.is_deleted OR t.user_id IS NOT NULL
        ORDER BY k.place, (t.user_id IS NOT NULL) DESC,
                 CASE WHEN k.place = #{SPELLED_CLOSE} THEN k.close END DESC NULLS LAST,
                 w.messages_posted DESC NULLS LAST, k.close DESC, k.is_deleted, k.user_id
        LIMIT :limit OFFSET :offset
      SQL
    end

    def picked(limit, case_id, who)
      ApplicationRecord.sanitize_sql_array([<<~SQL, binds.merge(limit: limit, case_id: case_id)])
        WITH #{ranked('SELECT user_id FROM fd.member WHERE user_id = :upper', who)}
        SELECT k.user_id
        FROM kept k
        LEFT JOIN analytics.fct_member_window w
          ON w.source = :lifetime AND w.user_id = k.user_id
        ORDER BY #{pick_order(case_id)}
        LIMIT :limit
      SQL
    end

    def pick_order(case_id)
      on_case = "EXISTS (SELECT 1 FROM fd.case_participants party " \
                "WHERE party.user_id = k.user_id AND party.case_id = :case_id) DESC"
      ["k.place", (on_case if case_id), "CASE WHEN k.place = #{SPELLED_CLOSE} THEN k.close END DESC NULLS LAST",
       "k.is_deleted", "k.is_bot", "w.messages_posted DESC NULLS LAST", "k.close DESC", "k.user_id"]
        .compact.join(", ")
    end

    def ranked(asked, who)
      <<~SQL.chomp
        exact AS (#{exact_email}),
        asked AS (#{words.one? ? asked : NOTHING}),
        candidates AS (#{candidates}),
        named AS (
          SELECT m.user_id, m.is_deleted, m.is_bot, #{names},
                 translate(lower(concat_ws(' ', m.display_name, m.handle)), '._-@', '    ') AS seen_text,
                 translate(lower(concat_ws(' ', #{text_fields})), '._-@', '    ') AS text
          FROM candidates c
          JOIN fd.member m ON m.user_id = c.user_id
          #{identity_joins}
          WHERE #{who}
        ),
        scored AS (
          SELECT user_id, is_deleted, is_bot,
                 CASE WHEN :whole IN (shown, handle) THEN #{SEEN_EXACT}
                      #{"WHEN :whole IN (real_name, full_name, cachet) THEN #{HIDDEN_EXACT}" if @identity}
                      WHEN (' ' || translate(shown, '._-@', '    ')) LIKE :phrase
                        OR (' ' || translate(handle, '._-@', '    ')) LIKE :phrase THEN #{SEEN_PHRASE}
                      WHEN #{every_word("(' ' || seen_text) LIKE :start")} THEN #{SEEN_START}
                      WHEN #{every_word("(' ' || text) LIKE :start")} THEN #{HIDDEN_START}
                      WHEN #{every_word('seen_text LIKE :within')} THEN #{SEEN_WITHIN}
                      WHEN #{every_word('text LIKE :within')} THEN #{HIDDEN_WITHIN}
                      ELSE #{SPELLED_CLOSE} END AS place,
                 greatest(#{closeness}) AS close
          FROM named
        ),
        kept AS (
          SELECT user_id, #{SEEN_EXACT} AS place, 1::real AS close, false AS is_deleted, false AS is_bot
          FROM exact
          UNION ALL
          SELECT user_id, #{SEEN_EXACT}, 1::real, false, false FROM asked
          WHERE NOT EXISTS (SELECT 1 FROM exact)
          UNION ALL
          SELECT user_id, place, close, is_deleted, is_bot FROM scored
          WHERE NOT EXISTS (SELECT 1 FROM exact) AND (#{keeps})
            AND user_id NOT IN (SELECT user_id FROM asked)
        )
      SQL
    end

    def short?
      words.all? { |word| word.length < TRIGRAM }
    end

    def leading?
      short? && words.one?
    end

    def phrase?
      short? && words.many?
    end

    def fuzzy?
      !phrase? && words.join(" ").length >= FUZZY_FROM
    end

    def keeps
      held = [leading? ? "place < #{SEEN_WITHIN}" : "place < #{SPELLED_CLOSE}"]
      held << "close >= :close_enough" if fuzzy?
      held.join(" OR ")
    end

    def binds
      whole = words.join(" ")
      longest = words.max_by(&:length).to_s
      held = { whole: whole, upper: words.first.to_s.upcase,
               anchor: "%#{like(phrase? ? whole : longest)}%", leading: "#{like(longest)}%",
               word_leading: "% #{like(longest)}%", phrase: "% #{like(whole)}%", email: email,
               close_enough: CLOSE_ENOUGH, lifetime: Analytics::MemberWindow::LIFETIME_SOURCE }
      words.each_with_index do |word, i|
        held[:"start#{i}"] = "% #{like(word)}%"
        held[:"within#{i}"] = "%#{like(word)}%"
      end
      held
    end

    def every_word(test)
      words.each_index.map { |i| test.sub(/:(start|within)\b/) { ":#{Regexp.last_match(1)}#{i}" } }
        .join(" AND ")
    end

    def like(text)
      ApplicationRecord.sanitize_sql_like(text)
    end

    def exact_email
      return NOTHING unless email

      "SELECT user_id FROM fd.member_identity WHERE lower(email) = :email AND purged_at IS NULL"
    end

    def candidates
      found = ["SELECT user_id FROM fd.member WHERE #{matching(%w[display_name handle])}" \
               "#{' OR lower(display_name) % :whole' if fuzzy?}"]
      if @identity
        found << "SELECT user_id FROM fd.member_identity WHERE purged_at IS NULL AND " \
                 "(#{matching(%w[real_name first_name last_name email])}" \
                 "#{' OR lower(real_name) % :whole' if fuzzy?})"
        found << "SELECT user_id FROM app.cachet_profiles WHERE #{matching(%w[display_name])}"
      end
      found.join(" UNION ")
    end

    def matching(fields)
      fields.map { |field|
        if leading?
          "lower(#{field}) LIKE :leading OR lower(#{field}) LIKE :word_leading"
        else
          "lower(#{field}) LIKE :anchor"
        end
      }.join(" OR ")
    end

    def names
      held = ["lower(m.display_name) AS shown", "lower(m.handle) AS handle"]
      if @identity
        held += ["lower(mi.real_name) AS real_name",
                 "lower(concat_ws(' ', mi.first_name, mi.last_name)) AS full_name",
                 "lower(cp.display_name) AS cachet"]
      end
      held.join(", ")
    end

    def text_fields
      held = %w[m.display_name m.handle]
      held += %w[mi.real_name mi.first_name mi.last_name mi.email cp.display_name] if @identity
      held.join(", ")
    end

    def identity_joins
      return "" unless @identity

      "LEFT JOIN fd.member_identity mi ON mi.user_id = m.user_id AND mi.purged_at IS NULL " \
        "LEFT JOIN app.cachet_profiles cp ON cp.user_id = m.user_id"
    end

    def closeness
      held = ["similarity(coalesce(shown, ''), :whole)", "similarity(coalesce(handle, ''), :whole)"]
      held << "similarity(coalesce(real_name, ''), :whole)" if @identity
      held.join(", ")
    end
  end
end
