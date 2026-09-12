module Channels
  module Joins
    RANGE = "r".freeze
    MOMENTUM = "m".freeze
    ROLLUP = "a".freeze

    SPINE = "dim_channel".freeze

    RANGE_JOIN = "LEFT JOIN analytics.mart_channel_range #{RANGE} " \
                 "ON #{RANGE}.channel_id = #{SPINE}.channel_id".freeze
    MOMENTUM_JOIN = "LEFT JOIN analytics.mart_channel_momentum #{MOMENTUM} " \
                    "ON #{MOMENTUM}.channel_id = #{SPINE}.channel_id".freeze
  end
end
