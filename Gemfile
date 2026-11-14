# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# test/run.rb needs only minitest. The skill examples test runs the clinic
# fixture with its own bundle, test/fixture/clinic/Gemfile.
gem "minitest", "6.0.6"

# Type checking: rbs-inline turns the comments in lib/ into sig/generated,
# and Steep checks lib/ against them.
group :types do
  gem "steep", "2.1.0", require: false
  gem "rbs-inline", "0.14.0", require: false
end
