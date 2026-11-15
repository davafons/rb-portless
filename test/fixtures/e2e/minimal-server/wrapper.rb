# frozen_string_literal: true

# Port of wrapper.js: spawns server.rb as a child so the dev server is a
# grandchild of the CLI (reproduces the orphaned-grandchild bug).
pid = Process.spawn(RbConfig.ruby, File.join(__dir__, "server.rb"))
_, status = Process.wait2(pid)
exit(status.exitstatus || 0)
