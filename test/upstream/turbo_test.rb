# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/config"

# Mirror of packages/portless/src/turbo.test.ts
module TurboTestSetup
  include UpstreamConfigSupport

  def self.included(base)
    base.class_eval do
      before { @tmp_dir = create_tmp_dir("portless-turbo-test-") }
      after { cleanup_dir(@tmp_dir) }
    end
  end
end

describe "hasTurboConfig" do
  include TurboTestSetup

  it "returns true when turbo.json exists" do
    write(File.join(@tmp_dir, "turbo.json"), "{}")
    _(Portless::Turbo.turbo_config?(@tmp_dir)).must_equal true
  end

  it "returns true when turbo.jsonc exists" do
    write(File.join(@tmp_dir, "turbo.jsonc"), "{\n  // Turbo supports comments\n  \"tasks\": {}\n}\n")
    _(Portless::Turbo.turbo_config?(@tmp_dir)).must_equal true
  end

  it "returns true when both Turbo configuration files exist" do
    write(File.join(@tmp_dir, "turbo.json"), "{}")
    write(File.join(@tmp_dir, "turbo.jsonc"), "{\n  // Turbo supports comments\n}\n")
    _(Portless::Turbo.turbo_config?(@tmp_dir)).must_equal true
  end

  it "returns false when neither Turbo configuration file exists" do
    _(Portless::Turbo.turbo_config?(@tmp_dir)).must_equal false
  end
end

describe "ensureEnvLoader" do
  include TurboTestSetup

  it "creates the loader file" do
    Portless::Turbo.ensure_env_loader(@tmp_dir)
    target = Portless::Turbo.loader_path(@tmp_dir)
    _(File.exist?(target)).must_equal true
    content = File.read(target)
    _(content).must_include "dev-manifest.json"
    _(content).must_include "process.env"
  end

  it "is idempotent" do
    Portless::Turbo.ensure_env_loader(@tmp_dir)
    first = File.read(Portless::Turbo.loader_path(@tmp_dir))
    Portless::Turbo.ensure_env_loader(@tmp_dir)
    second = File.read(Portless::Turbo.loader_path(@tmp_dir))
    _(first).must_equal second
  end

  it "updates the loader if source changes" do
    target = Portless::Turbo.loader_path(@tmp_dir)
    File.write(target, "old content")
    Portless::Turbo.ensure_env_loader(@tmp_dir)
    _(File.read(target)).must_equal Portless::Turbo.loader_source(@tmp_dir)
  end
end

describe "writeManifest / removeManifest" do
  include TurboTestSetup

  it "writes and reads manifest JSON" do
    entries = {
      "/path/to/app" => {
        "PORT" => "3001",
        "HOST" => "127.0.0.1",
        "PORTLESS_URL" => "https://app.project.local"
      }
    }
    Portless::Turbo.write_manifest(entries, @tmp_dir)
    raw = File.read(Portless::Turbo.manifest_path(@tmp_dir))
    _(JSON.parse(raw)).must_equal entries
  end

  it "includes NODE_EXTRA_CA_CERTS when provided" do
    entries = {
      "/path/to/app" => {
        "PORT" => "3001",
        "HOST" => "127.0.0.1",
        "PORTLESS_URL" => "https://app.project.local",
        "NODE_EXTRA_CA_CERTS" => "/home/user/.portless/ca.pem"
      }
    }
    Portless::Turbo.write_manifest(entries, @tmp_dir)
    raw = File.read(Portless::Turbo.manifest_path(@tmp_dir))
    _(JSON.parse(raw)["/path/to/app"]["NODE_EXTRA_CA_CERTS"]).must_equal "/home/user/.portless/ca.pem"
  end

  it "removeManifest deletes the file" do
    Portless::Turbo.write_manifest({}, @tmp_dir)
    _(File.exist?(Portless::Turbo.manifest_path(@tmp_dir))).must_equal true
    Portless::Turbo.remove_manifest(@tmp_dir)
    _(File.exist?(Portless::Turbo.manifest_path(@tmp_dir))).must_equal false
  end

  it "removeManifest is safe when file does not exist" do
    Portless::Turbo.remove_manifest(@tmp_dir)
  end
end

describe "buildNodeOptions" do
  include UpstreamConfigSupport

  before do
    @tmp_dir = create_tmp_dir("portless-turbo-test-")
    @original_node_options = ENV.fetch("NODE_OPTIONS", nil)
  end

  after do
    cleanup_dir(@tmp_dir)
    ENV["NODE_OPTIONS"] = @original_node_options
  end

  it "sets --require when NODE_OPTIONS is empty" do
    ENV.delete("NODE_OPTIONS")
    result = Portless::Turbo.build_node_options(@tmp_dir)
    _(result).must_equal "--require #{Portless::Turbo.loader_path(@tmp_dir)}"
  end

  it "prepends --require to existing NODE_OPTIONS" do
    ENV["NODE_OPTIONS"] = "--max-old-space-size=4096"
    result = Portless::Turbo.build_node_options(@tmp_dir)
    _(result).must_equal "--require #{Portless::Turbo.loader_path(@tmp_dir)} --max-old-space-size=4096"
  end

  it "quotes the loader path when it contains spaces" do
    ENV.delete("NODE_OPTIONS")
    spaced_dir = File.join(@tmp_dir, "path with spaces")
    FileUtils.mkdir_p(spaced_dir)
    result = Portless::Turbo.build_node_options(spaced_dir)
    _(result).must_equal "--require \"#{Portless::Turbo.loader_path(spaced_dir)}\""
  end
end

describe "loaderSource" do
  it "references the correct manifest path" do
    source = Portless::Turbo.loader_source("/custom/base")
    _(source).must_include "/custom/base"
    _(source).must_include "dev-manifest.json"
  end

  it "escapes backslashes for Windows paths" do
    source = Portless::Turbo.loader_source("C:\\Users\\test\\.portless")
    _(source).must_include "dev-manifest.json"
    # JSON.generate produces doubled backslashes in the JS source text.
    # Verify exactly doubled (not quadrupled from a redundant manual escape).
    _(source).must_include "C:\\\\Users\\\\test\\\\.portless"
    _(source).wont_include "C:\\\\\\\\Users"
  end
end
