module Fd
  class LinkedCases
    ROOT_HOPS = 10

    Target = Struct.new(:case_id, :report_id, :root_id, keyword_init: true)

    def self.for(refs)
      refs = Array(refs).uniq
      return {} if refs.empty?

      thread_ts = refs.map(&:thread_ts).uniq
      found = threads(thread_ts)
      roots = roots_for(found.values.map(&:first).uniq)

      refs.each_with_object({}) do |ref, targets|
        case_id, report_id = found[[ref.channel_id, ref.thread_ts]] || found[[nil, ref.thread_ts]]
        next if case_id.nil?

        targets[[ref.channel_id, ref.thread_ts]] =
          Target.new(case_id: case_id, report_id: report_id, root_id: roots.fetch(case_id, case_id))
      end
    end

    def self.threads(thread_ts)
      found = {}
      CaseThread.where(thread_ts: thread_ts).pluck(:channel_id, :thread_ts, :case_id)
        .each { |channel_id, ts, case_id| found[[channel_id, ts]] ||= [case_id, nil] }
      Case.where(card_thread_ts: thread_ts).pluck(:card_channel_id, :card_thread_ts, :id)
        .each { |channel_id, ts, case_id| found[[channel_id, ts]] = [case_id, nil] }
      CaseReport.where(forwarded_ts: thread_ts).order(:id).pluck(:card_channel_id, :forwarded_ts, :case_id, :id)
        .each { |channel_id, ts, case_id, report_id| found[[channel_id, ts]] = [case_id, report_id] }
      found
    end

    def self.roots_for(case_ids)
      parents = {}
      frontier = case_ids
      ROOT_HOPS.times do
        rows = Case.where(id: frontier).where.not(duplicate_of: nil).pluck(:id, :duplicate_of)
        break if rows.empty?

        rows.each { |id, parent| parents[id] = parent }
        frontier = rows.map(&:last) - parents.keys
      end
      case_ids.index_with { |id| climb(id, parents) }
    end

    def self.climb(id, parents)
      current = id
      ROOT_HOPS.times do
        break unless parents.key?(current)

        current = parents[current]
      end
      current
    end
  end
end
