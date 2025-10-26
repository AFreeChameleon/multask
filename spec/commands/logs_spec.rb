require "open3"
require "support/file_helper"
require "support/process_helper"

RSpec.describe "mlt logs" do

  it "Test simple only stdout logs" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi"
    sleep 0.1
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} logs 1"

    expect(stdout).to include "[STDOUT]"
    expect(stdout).to include "hi"

  end

  it "Test simple stdout and stderr logs" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c \"echo hi && invalidcommand\""
    sleep 0.1
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} logs 1"

    expect(stdout).to include "[STDOUT]"
    expect(stdout).to include "hi"

    expect(stdout).to include "[STDERR]"
    if FileHelpers.is_unix
      expect(stdout).to include "command not found"
    else
      expect(stdout).to include "'invalidcommand' is not recognized as an internal or external command"
    end
  end

  it "Test opening logs of task that doesn't exist" do
    _, stderr, _ = Open3.capture3 "#{FileHelpers.get_exe} logs 1"
    sleep 0.1

    expect(stderr).to include "[ERROR]"
    expect(stderr).to include "Task does not exist"
  end
end
