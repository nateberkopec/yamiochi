# frozen_string_literal: true

require "tmpdir"

require_relative "../test_helper"

class YamiochiRackupHandlerTest < Minitest::Test
  def test_registers_the_yamiochi_handler
    with_stubbed_rackup_handler do
      assert_same Rackup::Handler::Yamiochi, Rackup::Handler.get(:yamiochi)
    end
  end

  def test_run_delegates_to_yamiochi_server_with_app_host_and_port
    with_stubbed_rackup_handler do
      app = ->(_env) { [200, {}, ["ok"]] }
      server_instance = Object.new
      calls = []

      server_instance.define_singleton_method(:run) { self }

      server_singleton = Yamiochi::Server.singleton_class
      original_new = Yamiochi::Server.method(:new)

      begin
        server_singleton.send(:define_method, :new) do |**kwargs|
          calls << kwargs
          server_instance
        end

        result = Rackup::Handler::Yamiochi.run(app, Host: "127.0.0.1", Port: "9393")

        assert_same server_instance, result
      ensure
        server_singleton.send(:define_method, :new, original_new)
      end

      assert_equal [{app: app, host: "127.0.0.1", port: "9393"}], calls
    end
  end

  private

  def with_stubbed_rackup_handler
    rackup_was_defined = Object.const_defined?(:Rackup, false)

    Dir.mktmpdir("yamiochi-rackup-handler-test") do |dir|
      write_rackup_handler_stub(dir)
      $LOAD_PATH.unshift(dir)

      begin
        load rackup_handler_path
        yield
      ensure
        $LOAD_PATH.delete(dir)
        $LOADED_FEATURES.reject! { |feature| feature.start_with?(dir) }
        Object.send(:remove_const, :Rackup) if !rackup_was_defined && Object.const_defined?(:Rackup, false)
      end
    end
  end

  def write_rackup_handler_stub(dir)
    rackup_dir = File.join(dir, "rackup")
    Dir.mkdir(rackup_dir)

    File.write(File.join(rackup_dir, "handler.rb"), <<~RUBY)
      module Rackup
        module Handler
          @handlers = {}

          class << self
            def register(name, handler)
              @handlers[name.to_sym] = handler
            end

            def get(name)
              @handlers[name.to_sym]
            end
          end
        end
      end
    RUBY
  end

  def rackup_handler_path
    File.expand_path("../../lib/rackup/handler/yamiochi.rb", __dir__)
  end
end
