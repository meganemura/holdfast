RSpec.configure do |config|
  config.expect_with(:rspec) { _1.include_chain_clauses_in_custom_matcher_descriptions = true }
end
