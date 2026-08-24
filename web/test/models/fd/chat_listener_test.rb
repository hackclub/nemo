require "test_helper"

class Fd::ChatListenerTest < ActiveSupport::TestCase
  test "a payload that is a case number is read as one" do
    assert_equal 2633, Fd::ChatListener.case_id_from("2633")
  end

  test "anything else is ignored rather than raising in the listener thread" do
    assert_nil Fd::ChatListener.case_id_from("case 2633")
    assert_nil Fd::ChatListener.case_id_from("")
    assert_nil Fd::ChatListener.case_id_from(nil)
  end

  test "the listener stays out of the test suite" do
    assert_not Fd::ChatListener.wanted?
  end

  test "a console or a rake task is not a server, so it does not listen" do
    assert_not Fd::ChatListener.serving?
  end

  test "saying no in any of the usual spellings turns it off" do
    %w[0 false no off FALSE Off].each do |said|
      with_env("NEMO_STREAM", said) do
        assert_not Fd::ChatListener.wanted?, "NEMO_STREAM=#{said} should not stream"
      end
    end
  end

  test "anything else asked for turns it on, whatever the process is called" do
    %w[1 true yes on].each do |said|
      with_env("NEMO_STREAM", said) do
        assert Fd::ChatListener.wanted?, "NEMO_STREAM=#{said} should stream"
      end
    end
  end

  test "an empty setting is not an answer, so the process decides" do
    with_env("NEMO_STREAM", "") do
      assert_equal Fd::ChatListener.serving?, Fd::ChatListener.wanted?
    end
  end

  def with_env(name, value)
    was, had, serving = ENV[name], ENV.key?(name), Rails.env
    ENV[name] = value
    Rails.env = "production"
    yield
  ensure
    Rails.env = serving
    had ? ENV[name] = was : ENV.delete(name)
  end

  test "it connects on its own terms, not out of the request pool" do
    said = {
      host: "db.example", port: 5432, database: "mnemosyne",
      username: "rails_app", password: "secret", pool: 5, adapter: "postgresql"
    }

    assert_equal({ host: "db.example", port: 5432, dbname: "mnemosyne",
                   user: "rails_app", password: "secret" },
      Fd::ChatListener.connection_options(said))
  end

  test "a socket with nothing configured for it is left out" do
    assert_equal({ dbname: "mnemosyne" }, Fd::ChatListener.connection_options(database: "mnemosyne"))
  end

  class Cut
    attr_reader :closed, :listened

    def initialize = (@listened = []; @closed = false)
    def exec(sql) = @listened << sql
    def close = @closed = true
    def wait_for_notify(_wait) = raise(PG::ConnectionBad, "the server went away")
  end

  test "a connection that dies is closed, not left behind" do
    cut = Cut.new

    assert_raises(PG::ConnectionBad) { Fd::ChatListener.new.send(:listen, cut) }

    assert cut.closed, "every retry would otherwise strand a backend and drain the pool"
    assert_equal ["LISTEN fd_chat_changed", "LISTEN fd_conversation_changed"], cut.listened
  end

  test "the pool is untouched by listening" do
    pool = ActiveRecord::Base.connection_pool

    assert_no_difference -> { pool.stat[:busy] } do
      assert_raises(PG::ConnectionBad) { Fd::ChatListener.new.send(:listen, Cut.new) }
    end
  end
end
