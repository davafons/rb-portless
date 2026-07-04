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

  # Both sides of the version handshake are printed, matching or not — a stale
  # daemon (old code in memory) is invisible without it.
  def test_app_banner_shows_gem_and_proxy_versions
    _out, err = capture_io do
      Portless::Banner.app(rows: [], backend_port: 4321, proxy_version: Portless::VERSION)
    end
    assert_includes err, "v#{Portless::VERSION} · proxy v#{Portless::VERSION}"
  end

  def test_app_banner_omits_the_proxy_version_when_unknown
    _out, err = capture_io { Portless::Banner.app(rows: [], backend_port: 4321) }
    assert_includes err, "v#{Portless::VERSION}"
    refute_includes err, "proxy v"
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
