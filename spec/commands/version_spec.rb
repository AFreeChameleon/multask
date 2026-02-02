require "open3"
require "support/file_helper"
require "support/process_helper"

RSpec.describe "mlt version" do
  it "Test simple version" do
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} version"

    expect(stdout).to include "v0.5.2"
  end
end
