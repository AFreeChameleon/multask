require "open3"
require "support/file_helper"

RSpec.configure do |config|
  config.before :each do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} delete all"
    FileHelpers.reset
  end
  config.after :each do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} delete all"
    FileHelpers.reset
  end

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
end
