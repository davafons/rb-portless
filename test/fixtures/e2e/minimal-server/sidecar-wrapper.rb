# frozen_string_literal: true

# Port of sidecar-wrapper.js: spawns server.rb plus an idle sidecar that never
# listens on the app port (like turbo's helpers) and records the sidecar PID.
sidecar = Process.spawn(RbConfig.ruby, "-e", "loop { sleep 1 }")
File.write(ENV.fetch("SIDECAR_PID_FILE"), sidecar.to_s)
pid = Process.spawn(RbConfig.ruby, File.join(__dir__, "server.rb"))
_, status = Process.wait2(pid)
exit(status.exitstatus || 0)
