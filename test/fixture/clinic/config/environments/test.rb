Rails.application.configure do
  config.active_job.queue_adapter = :test
  config.enable_reloading = false
  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :rescuable
  config.active_support.deprecation = :stderr
end
