# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "minitest", "~> 5.0"
  gem "rake", "~> 13.0"
  gem "rubocop-rails-omakase", require: false

  # A real Rails app for the end-to-end railtie tests (test/e2e_rails_test.rb).
  gem "actioncable", ">= 7.1"
  gem "actionmailer", ">= 7.1"
  gem "railties", ">= 7.1"
  gem "rackup"
  gem "webrick"
end
