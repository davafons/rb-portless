# frozen_string_literal: true

require_relative "lib/portless/version"

Gem::Specification.new do |spec|
  spec.name = "portless-rb"
  spec.version = Portless::VERSION
  spec.authors = [ "David Afonso" ]
  spec.email = [ "dav@davafons.com" ]

  spec.summary = "Replace localhost port numbers with stable, named .localhost URLs."
  spec.description = <<~DESC
    A native-Ruby port of Vercel's portless. Run your dev server through a local
    reverse proxy and reach it at https://<name>.localhost instead of a port —
    HTTPS by default, with an on-demand local CA, per-host certs, and a random
    backend port so you never collide on 3000/3001 again. Framework-agnostic;
    first-class with Rails.
  DESC
  spec.homepage = "https://github.com/davafons/portless-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "AGENTS.md", "CHANGELOG.md", "LICENSE"]
  spec.bindir = "exe"
  spec.executables = [ "portless-rb" ]
  spec.require_paths = [ "lib" ]

  # async-http gives HTTP/1.1 + HTTP/2 + TLS + WebSockets natively — the Ruby
  # equivalent of the Node http2 server portless builds on.
  spec.add_dependency "async", "~> 2.0"
  spec.add_dependency "async-http", "~> 0.80"
end
