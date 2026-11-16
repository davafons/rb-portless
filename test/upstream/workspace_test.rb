# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/config"

# Mirror of packages/portless/src/workspace.test.ts
module WorkspaceTestSetup
  include UpstreamConfigSupport

  def self.included(base)
    base.class_eval do
      before { @tmp_dir = create_tmp_dir("portless-ws-test-") }
      after { cleanup_dir(@tmp_dir) }
    end
  end
end

describe "parsePnpmWorkspaceYaml" do
  def parse(content) = Portless::Workspace.parse_pnpm_workspace_yaml(content)

  it "parses basic packages list" do
    content = <<~YAML
      packages:
        - apps/*
        - packages/*
    YAML
    _(parse(content)).must_equal [ "apps/*", "packages/*" ]
  end

  it "handles comments and blank lines" do
    content = <<~YAML
      packages:
        # Apps directory
        - apps/*

        # Packages directory
        - packages/*
    YAML
    _(parse(content)).must_equal [ "apps/*", "packages/*" ]
  end

  it "handles quoted values" do
    content = <<~YAML
      packages:
        - 'apps/*'
        - "packages/*"
    YAML
    _(parse(content)).must_equal [ "apps/*", "packages/*" ]
  end

  it "returns empty array when no packages key" do
    _(parse("version: 1")).must_equal []
  end

  it "returns empty array for empty content" do
    _(parse("")).must_equal []
  end

  it "stops at next top-level key" do
    content = <<~YAML
      packages:
        - apps/*
      catalog:
        react: 19
    YAML
    _(parse(content)).must_equal [ "apps/*" ]
  end

  it "handles negation patterns" do
    content = <<~YAML
      packages:
        - apps/*
        - '!apps/legacy'
    YAML
    _(parse(content)).must_equal [ "apps/*", "!apps/legacy" ]
  end

  it "handles inline comments" do
    content = <<~YAML
      packages:
        - apps/* # the apps
        - packages/*
    YAML
    _(parse(content)).must_equal [ "apps/*", "packages/*" ]
  end

  it "parses flow sequence on same line" do
    _(parse("packages: [apps/*, packages/*]")).must_equal [ "apps/*", "packages/*" ]
  end

  it "parses flow sequence with quotes" do
    _(parse(%(packages: ['apps/*', "packages/*"]))).must_equal [ "apps/*", "packages/*" ]
  end
end

describe "expandPackageGlobs" do
  include WorkspaceTestSetup

  def expand(*args) = Portless::Workspace.expand_package_globs(*args)

  it "expands wildcard globs to directories" do
    FileUtils.mkdir_p(File.join(@tmp_dir, "apps", "web"))
    FileUtils.mkdir_p(File.join(@tmp_dir, "apps", "api"))
    # Create a file to ensure it's filtered out
    write(File.join(@tmp_dir, "apps", "README.md"), "")

    result = expand(@tmp_dir, [ "apps/*" ])
    _(result.length).must_equal 2
    _(result).must_include File.join(@tmp_dir, "apps", "api")
    _(result).must_include File.join(@tmp_dir, "apps", "web")
  end

  it "handles literal directory paths" do
    FileUtils.mkdir_p(File.join(@tmp_dir, "tools"))
    _(expand(@tmp_dir, [ "tools" ])).must_equal [ File.join(@tmp_dir, "tools") ]
  end

  it "handles negation patterns" do
    FileUtils.mkdir_p(File.join(@tmp_dir, "apps", "web"))
    FileUtils.mkdir_p(File.join(@tmp_dir, "apps", "legacy"))

    result = expand(@tmp_dir, [ "apps/*", "!apps/legacy" ])
    _(result.length).must_equal 1
    _(result).must_include File.join(@tmp_dir, "apps", "web")
  end

  it "returns empty for non-existent base directory" do
    _(expand(@tmp_dir, [ "nonexistent/*" ])).must_equal []
  end

  it "handles double-star globs same as single star" do
    FileUtils.mkdir_p(File.join(@tmp_dir, "packages", "shared"))
    result = expand(@tmp_dir, [ "packages/**" ])
    _(result.length).must_equal 1
    _(result).must_include File.join(@tmp_dir, "packages", "shared")
  end

  it "handles mid-path wildcard (packages/*/src)" do
    shared_src = File.join(@tmp_dir, "packages", "shared", "src")
    utils_src = File.join(@tmp_dir, "packages", "utils", "src")
    FileUtils.mkdir_p(shared_src)
    FileUtils.mkdir_p(utils_src)
    # A package without src should not match
    FileUtils.mkdir_p(File.join(@tmp_dir, "packages", "no-src"))

    result = expand(@tmp_dir, [ "packages/*/src" ])
    _(result.length).must_equal 2
    _(result).must_include shared_src
    _(result).must_include utils_src
  end

  it "handles prefix wildcard (apps/team-*)" do
    FileUtils.mkdir_p(File.join(@tmp_dir, "apps", "team-alpha"))
    FileUtils.mkdir_p(File.join(@tmp_dir, "apps", "team-beta"))
    FileUtils.mkdir_p(File.join(@tmp_dir, "apps", "other"))

    result = expand(@tmp_dir, [ "apps/team-*" ])
    _(result.length).must_equal 2
    _(result).must_include File.join(@tmp_dir, "apps", "team-alpha")
    _(result).must_include File.join(@tmp_dir, "apps", "team-beta")
  end

  it "does not crash on prefix wildcard with trailing segments" do
    FileUtils.mkdir_p(File.join(@tmp_dir, "apps", "team-alpha", "sub"))
    FileUtils.mkdir_p(File.join(@tmp_dir, "apps", "team-beta"))

    result = expand(@tmp_dir, [ "apps/team-*/sub" ])
    _(result.length).must_equal 1
    _(result).must_include File.join(@tmp_dir, "apps", "team-alpha", "sub")
  end
end

describe "readWorkspacesFromPackageJson" do
  include WorkspaceTestSetup

  def read_workspaces(dir) = Portless::Workspace.read_workspaces_from_package_json(dir)

  it "reads array-form workspaces" do
    write_json(File.join(@tmp_dir, "package.json"), { workspaces: [ "apps/*", "packages/*" ] })
    _(read_workspaces(@tmp_dir)).must_equal [ "apps/*", "packages/*" ]
  end

  it "reads yarn-classic object form" do
    write_json(File.join(@tmp_dir, "package.json"), { workspaces: { packages: [ "apps/*", "packages/*" ] } })
    _(read_workspaces(@tmp_dir)).must_equal [ "apps/*", "packages/*" ]
  end

  it "returns null when no workspaces field" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test" })
    _(read_workspaces(@tmp_dir)).must_be_nil
  end

  it "returns null when no package.json" do
    _(read_workspaces(@tmp_dir)).must_be_nil
  end

  it "filters non-string entries" do
    write_json(File.join(@tmp_dir, "package.json"), { workspaces: [ "apps/*", 42, nil, "packages/*" ] })
    _(read_workspaces(@tmp_dir)).must_equal [ "apps/*", "packages/*" ]
  end
end

describe "findWorkspaceRoot" do
  include WorkspaceTestSetup

  def find_root(dir) = Portless::Workspace.find_workspace_root(dir)

  it "finds pnpm-workspace.yaml in cwd" do
    write(File.join(@tmp_dir, "pnpm-workspace.yaml"), "packages:\n  - apps/*\n")
    _(find_root(@tmp_dir)).must_equal @tmp_dir
  end

  it "walks up to find pnpm-workspace.yaml" do
    write(File.join(@tmp_dir, "pnpm-workspace.yaml"), "packages:\n  - apps/*\n")
    sub_dir = File.join(@tmp_dir, "apps", "web", "src")
    FileUtils.mkdir_p(sub_dir)
    _(find_root(sub_dir)).must_equal @tmp_dir
  end

  it "returns null when no workspace root exists" do
    _(find_root(@tmp_dir)).must_be_nil
  end

  it "finds package.json workspaces in cwd" do
    write_json(File.join(@tmp_dir, "package.json"), { workspaces: [ "apps/*" ] })
    _(find_root(@tmp_dir)).must_equal @tmp_dir
  end

  it "walks up to find package.json workspaces" do
    write_json(File.join(@tmp_dir, "package.json"), { workspaces: [ "apps/*" ] })
    sub_dir = File.join(@tmp_dir, "apps", "web")
    FileUtils.mkdir_p(sub_dir)
    _(find_root(sub_dir)).must_equal @tmp_dir
  end

  it "prefers pnpm-workspace.yaml over package.json workspaces" do
    write(File.join(@tmp_dir, "pnpm-workspace.yaml"), "packages:\n  - pnpm-apps/*\n")
    write_json(File.join(@tmp_dir, "package.json"), { workspaces: [ "npm-apps/*" ] })
    _(find_root(@tmp_dir)).must_equal @tmp_dir
  end

  it "ignores package.json without workspaces field" do
    write_json(File.join(@tmp_dir, "package.json"), { name: "test" })
    _(find_root(@tmp_dir)).must_be_nil
  end
end

describe "discoverWorkspacePackages" do
  include WorkspaceTestSetup

  def discover(dir) = Portless::Workspace.discover_workspace_packages(dir)

  it "discovers packages with package.json" do
    write(File.join(@tmp_dir, "pnpm-workspace.yaml"), "packages:\n  - apps/*\n")
    web_dir = File.join(@tmp_dir, "apps", "web")
    write_json(File.join(web_dir, "package.json"), { name: "@myorg/web", scripts: { dev: "next dev" } })

    packages = discover(@tmp_dir)
    _(packages.length).must_equal 1
    _(packages[0].name).must_equal "web"
    _(packages[0].scope).must_equal "myorg"
    _(packages[0].scripts["dev"]).must_equal "next dev"
    _(packages[0].dir).must_equal web_dir
  end

  it "strips @scope/ from package names and preserves scope" do
    write(File.join(@tmp_dir, "pnpm-workspace.yaml"), "packages:\n  - apps/*\n")
    web_dir = File.join(@tmp_dir, "apps", "web")
    write_json(File.join(web_dir, "package.json"), { name: "@company/web-app" })

    packages = discover(@tmp_dir)
    _(packages[0].name).must_equal "web-app"
    _(packages[0].scope).must_equal "company"
  end

  it "handles packages without a name field" do
    write(File.join(@tmp_dir, "pnpm-workspace.yaml"), "packages:\n  - apps/*\n")
    web_dir = File.join(@tmp_dir, "apps", "web")
    write_json(File.join(web_dir, "package.json"), { scripts: { dev: "next dev" } })

    packages = discover(@tmp_dir)
    _(packages[0].name).must_be_nil
    _(packages[0].scope).must_be_nil
  end

  it "handles unscoped package names" do
    write(File.join(@tmp_dir, "pnpm-workspace.yaml"), "packages:\n  - apps/*\n")
    web_dir = File.join(@tmp_dir, "apps", "web")
    write_json(File.join(web_dir, "package.json"), { name: "my-app" })

    packages = discover(@tmp_dir)
    _(packages[0].name).must_equal "my-app"
    _(packages[0].scope).must_be_nil
  end

  it "skips directories without package.json" do
    write(File.join(@tmp_dir, "pnpm-workspace.yaml"), "packages:\n  - apps/*\n")
    FileUtils.mkdir_p(File.join(@tmp_dir, "apps", "empty"))

    _(discover(@tmp_dir).length).must_equal 0
  end

  it "discovers multiple packages from multiple globs" do
    write(File.join(@tmp_dir, "pnpm-workspace.yaml"), "packages:\n  - apps/*\n  - packages/*\n")

    [ "apps/web", "apps/api", "packages/shared" ].each do |dir|
      full = File.join(@tmp_dir, dir)
      write_json(File.join(full, "package.json"), { name: File.basename(dir), scripts: { dev: "echo dev" } })
    end

    packages = discover(@tmp_dir)
    _(packages.length).must_equal 3
    _(packages.map(&:name).sort).must_equal %w[api shared web]
  end

  it "returns empty when no workspace config exists" do
    _(discover(@tmp_dir)).must_equal []
  end

  it "discovers packages from package.json workspaces (npm/yarn/bun)" do
    write_json(File.join(@tmp_dir, "package.json"), { workspaces: [ "apps/*" ] })
    web_dir = File.join(@tmp_dir, "apps", "web")
    write_json(File.join(web_dir, "package.json"), { name: "@myorg/web", scripts: { dev: "next dev" } })

    packages = discover(@tmp_dir)
    _(packages.length).must_equal 1
    _(packages[0].name).must_equal "web"
    _(packages[0].scope).must_equal "myorg"
    _(packages[0].dir).must_equal web_dir
  end

  it "discovers packages from yarn-classic object workspaces" do
    write_json(File.join(@tmp_dir, "package.json"), { workspaces: { packages: [ "apps/*", "packages/*" ] } })
    [ "apps/web", "packages/shared" ].each do |dir|
      full = File.join(@tmp_dir, dir)
      write_json(File.join(full, "package.json"), { name: File.basename(dir), scripts: { dev: "echo dev" } })
    end

    packages = discover(@tmp_dir)
    _(packages.length).must_equal 2
    _(packages.map(&:name).sort).must_equal %w[shared web]
  end

  it "prefers pnpm-workspace.yaml over package.json workspaces" do
    write(File.join(@tmp_dir, "pnpm-workspace.yaml"), "packages:\n  - apps/*\n")
    write_json(File.join(@tmp_dir, "package.json"), { workspaces: [ "packages/*" ] })
    web_dir = File.join(@tmp_dir, "apps", "web")
    write_json(File.join(web_dir, "package.json"), { name: "web", scripts: { dev: "echo dev" } })
    shared_dir = File.join(@tmp_dir, "packages", "shared")
    write_json(File.join(shared_dir, "package.json"), { name: "shared", scripts: { dev: "echo dev" } })

    packages = discover(@tmp_dir)
    _(packages.length).must_equal 1
    _(packages[0].name).must_equal "web"
  end
end
