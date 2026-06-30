# frozen_string_literal: true

require_relative "test_helper"

# The OS-store install paths are side-effecting (keychain / update-ca-trust), so
# we only unit-test the pure NSS-DB discovery that feeds the Firefox/Chrome trust.
class TrustTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def test_finds_firefox_profiles_with_a_cert_db
    good = File.join(@home, ".mozilla", "firefox", "abc.default")
    empty = File.join(@home, ".mozilla", "firefox", "no-db.profile")
    touch_db(good)
    FileUtils.mkdir_p(empty) # profile dir without cert9.db is skipped

    profiles = Portless::Trust.firefox_profiles(@home)
    assert_includes profiles, good
    refute_includes profiles, empty
  end

  def test_finds_snap_and_flatpak_firefox_profiles
    snap = File.join(@home, "snap", "firefox", "common", ".mozilla", "firefox", "p1")
    flatpak = File.join(@home, ".var", "app", "org.mozilla.firefox", ".mozilla", "firefox", "p2")
    touch_db(snap)
    touch_db(flatpak)

    profiles = Portless::Trust.firefox_profiles(@home)
    assert_includes profiles, snap
    assert_includes profiles, flatpak
  end

  def test_nss_dbs_includes_chrome_shared_store_and_firefox
    pki = File.join(@home, ".pki", "nssdb")
    firefox = File.join(@home, ".mozilla", "firefox", "main")
    touch_db(pki)
    touch_db(firefox)

    dbs = Portless::Trust.nss_dbs(@home)
    assert_includes dbs, pki
    assert_includes dbs, firefox
  end

  def test_nss_dbs_is_empty_without_any_cert_db
    assert_empty Portless::Trust.nss_dbs(@home)
  end

  private

  def touch_db(dir)
    FileUtils.mkdir_p(dir)
    FileUtils.touch(File.join(dir, "cert9.db"))
  end
end
