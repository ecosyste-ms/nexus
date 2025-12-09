source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '3.4.7'

# Rails components
gem "activemodel", "~> 8.1.1"
gem "activerecord", "~> 8.1.1"
gem "actionpack", "~> 8.1.1"
gem "activesupport", "~> 8.1.1"
gem "railties", "~> 8.1.1"

gem "pg"
gem "puma"
gem "bootsnap", require: false
gem "redis"
gem "sidekiq"
gem 'sidekiq-unique-jobs'
gem "faraday"
gem "faraday-retry"
gem "faraday-follow_redirects"
gem "oj"
gem "pagy", "~> 9.4.0"
gem "pghero"
gem "pg_query"
gem 'rack-cors'
gem "lograge"
gem 'rack-timeout'
gem 'appsignal'

group :development do
  gem "web-console"
end

group :test do
  gem "shoulda-matchers"
  gem "shoulda-context", "~> 3.0.0.rc1"
  gem "webmock"
  gem "mocha"
  gem "rails-controller-testing"
end

group :development, :test do
  gem "dotenv-rails", "~> 3.2"
end
