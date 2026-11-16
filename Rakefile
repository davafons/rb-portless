# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError
  # rubocop is a dev-only convenience.
end


namespace :upstream do
  desc "Every upstream test has a same-named Ruby test in test/upstream (or a reason in skips.yml)"
  task :check do
    sh "script/upstream/check_tests"
  end

  desc "Report upstream changes since script/upstream/PIN (FETCH=1 to fetch first)"
  task :sync do
    sh "script/upstream/sync", *(ENV["FETCH"] ? [ "--fetch" ] : [])
  end
end

task default: %i[test upstream:check]
