# frozen_string_literal: true

# Port of stubborn-group.js: ignores SIGTERM and outlives its server child.
trap("TERM") { }
Process.spawn(RbConfig.ruby, File.join(__dir__, "server.rb"))
loop { sleep 1 }
