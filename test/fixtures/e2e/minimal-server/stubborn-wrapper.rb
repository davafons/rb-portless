# frozen_string_literal: true

# Port of stubborn-wrapper.js: ignores SIGTERM (via a handler, so the child
# does not inherit SIG_IGN) and lives as long as its server child.
trap("TERM") { }
pid = Process.spawn(RbConfig.ruby, File.join(__dir__, "server.rb"))
Process.wait(pid)
