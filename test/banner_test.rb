# frozen_string_literal: true

require_relative "test_helper"

class BannerTest < Minitest::Test
  def test_app_banner_lists_local_and_backend
    _out, err = capture_io do
      Portless::Banner.app(rows: [ [ "Local", "https://x.localhost", :cyan ] ], backend_port: 4321)
    end
    assert_includes err, "rb-portless"
    assert_includes err, "Local"
    assert_includes err, "https://x.localhost"
    assert_includes err, "Backend"
    assert_includes err, "127.0.0.1:4321"
  end

  def test_multi_banner_lists_every_app
    apps = [
      Portless::Multi::App.new(name: "web", url: "https://web.localhost"),
      Portless::Multi::App.new(name: "api", url: "https://api.localhost")
    ]
    _out, err = capture_io { Portless::Banner.multi(apps: apps) }
    assert_includes err, "web"
    assert_includes err, "https://web.localhost"
    assert_includes err, "api"
    assert_includes err, "https://api.localhost"
  end
end
