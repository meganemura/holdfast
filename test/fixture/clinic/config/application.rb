require_relative "boot"
require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
Bundler.require(*Rails.groups)

# The app the holdfast SKILL.md examples run against: appointments, a sweep
# job that charges no-show fees, and a desk check-in.
module Clinic
  class Application < Rails::Application
    config.load_defaults 8.1
    config.eager_load = false
  end
end
