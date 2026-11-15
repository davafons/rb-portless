# frozen_string_literal: true

require_relative "test_helper"

# formatUptime / formatUrl / escapeHtml / renderPage (utils.ts, pages.ts).
class PagesTest < Minitest::Test
  P = Portless::Pages
  NOW = 1_700_000_000_000

  def test_format_uptime
    assert_equal "45s", P.format_uptime(NOW - 45_000, NOW)
    assert_equal "12m", P.format_uptime(NOW - 12 * 60_000 - 59_000, NOW)
    assert_equal "2h", P.format_uptime(NOW - 2 * 3_600_000, NOW)
    assert_equal "3d", P.format_uptime(NOW - 3 * 86_400_000, NOW)
    assert_equal "0s", P.format_uptime(NOW + 30_000, NOW)
    assert_nil P.format_uptime(NOW + 61_000, NOW)
    assert_nil P.format_uptime(nil, NOW)
    assert_nil P.format_uptime(0, NOW)
    assert_nil P.format_uptime("1", NOW)
  end

  def test_format_url
    assert_equal "https://a.localhost", P.format_url("a.localhost", 443, true)
    assert_equal "http://a.localhost", P.format_url("a.localhost", 80)
    assert_equal "http://a.localhost:1355", P.format_url("a.localhost", 1355)
    assert_equal "https://a.localhost:80", P.format_url("a.localhost", 80, true)
  end

  def test_escape_html
    assert_equal "&lt;a href=&quot;x&quot;&gt;&amp;&#39;", P.escape_html(%(<a href="x">&'))
  end

  def test_render_page_embeds_fonts_and_status
    page = P.render_page(502, "Bad Gateway", "<p>x</p>")
    assert page.start_with?("<!DOCTYPE html>")
    assert_includes page, "<title>502 - Bad Gateway</title>"
    assert_includes page, "<h1>502</h1><h2>Bad Gateway</h2>"
    assert_includes page, Portless::Fonts::GEIST_PIXEL
    refute_includes page, "${"
  end
end
