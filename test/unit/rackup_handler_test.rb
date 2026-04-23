# frozen_string_literal: true

require "rackup"

require_relative "../test_helper"
require_relative "../../lib/rackup/handler/yamiochi"

class YamiochiRackupHandlerTest < Minitest::Test
  def test_registers_the_yamiochi_handler
    assert_same Rackup::Handler::Yamiochi, Rackup::Handler.get(:yamiochi)
  end

  def test_run_delegates_to_yamiochi_server_with_app_host_and_port
    app = ->(_env) { [200, {}, ["ok"]] }
    server_instance = Object.new
    calls = []

    server_instance.define_singleton_method(:run) { self }

    Yamiochi::Server.stub(:new, ->(**kwargs) {
      calls << kwargs
      server_instance
    }) do
      result = Rackup::Handler::Yamiochi.run(app, Host: "127.0.0.1", Port: "9393")

      assert_same server_instance, result
    end

    assert_equal [{ app: app, host: "127.0.0.1", port: "9393" }], calls
  end
end
