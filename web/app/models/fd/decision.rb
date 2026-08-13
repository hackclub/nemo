module Fd
  class Decision < ApplicationRecord
    self.table_name = "fd.decisions"

    class NotAllowed < StandardError; end

    STATES = %w[proposed settled superseded].freeze
    AMENDABLE = %w[title statement reasons category_key].freeze

    has_many :threads, -> { oldest_first }, class_name: "Fd::DecisionThread",
      foreign_key: :decision_id, inverse_of: :decision, dependent: nil
    belongs_to :replacement, class_name: "Fd::Decision", foreign_key: :replaced_by_id,
      inverse_of: :replaced, optional: true
    has_many :replaced, class_name: "Fd::Decision", foreign_key: :replaced_by_id,
      inverse_of: :replacement, dependent: nil

    scope :in_force, -> { where(state: "settled") }
    scope :unsettled, -> { where(state: "proposed") }
    scope :retired, -> { where(state: "superseded") }
    scope :live, -> { where.not(state: "superseded") }
    scope :of_category, ->(key) { where(category_key: key) }
    scope :newest_first, -> { order(Arel.sql("coalesce(settled_at, proposed_at) DESC")) }
    scope :oldest_first, -> { order(Arel.sql("coalesce(settled_at, proposed_at)")) }

    def title=(value)
      super(value.to_s.strip)
    end

    def statement=(value)
      super(value.to_s.strip)
    end

    def reasons=(value)
      super(Array(value).map { |line| line.to_s.strip }.reject(&:blank?))
    end

    def proposed? = state == "proposed"
    def settled? = state == "settled"
    def superseded? = state == "superseded"
    def live? = !superseded?

    def decided_at
      settled_at || proposed_at
    end

    def category_label
      category_key.present? ? Case.category_label(category_key) : nil
    end

    def settle!(by:, at: Time.current)
      refuse "decision #{id} is already settled" if settled?
      refuse "decision #{id} was superseded, write a new one instead" if superseded?

      update!(state: "settled", settled_by: by, settled_at: at)
    end

    def amend!(attrs)
      refuse "only a settled decision can be amended" unless settled?

      update!(attrs.to_h.transform_keys(&:to_s).slice(*AMENDABLE))
    end

    def supersede!(replacement, by:, at: Time.current)
      refuse "only a settled decision can be superseded" unless settled?
      refuse "a decision cannot supersede itself" if replacement.id == id
      refuse "the replacement was itself superseded" if replacement.superseded?

      update!(state: "superseded", retired_by: by, retired_at: at,
        replaced_by_id: replacement.id)
    end

    def droppable?
      proposed?
    end

    def drop!
      refuse "a settled decision is superseded, never dropped" unless droppable?

      destroy!
    end

    private

    def refuse(why)
      raise NotAllowed, why
    end
  end
end
