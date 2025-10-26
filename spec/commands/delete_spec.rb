require "open3"
require "support/file_helper"
require "support/process_helper"

RSpec.describe "mlt delete" do
  it "Test deleting simple task that isn't running" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi --no-run"
    sleep 0.1

    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} delete 1"
    sleep 0.1

    expect(stdout).to include "[SUCCESS]"
    expect(stdout).to include "Task deleted with id 1"
  end

  it "Test deleting task that is running" do
    command = FileHelpers.is_unix ? "sleep 5" : "powershell -C Start-Sleep -Seconds 5"
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c -- #{command}"

    running = ProcessHelpers.wait_for_task_running 1, 5

    expect(running).to be true

    stdout, stderr, _ = Open3.capture3 "#{FileHelpers.get_exe} delete 1"
    sleep 0.1

    expect(stderr).to be_empty

    expect(stdout).to include "Killing existing processes"

    expect(stdout).to include "[SUCCESS]"
    expect(stdout).to include "Task deleted with id 1"
  end

  it "Test deleting task that doesn't exist" do
    _, stderr, _ = Open3.capture3 "#{FileHelpers.get_exe} delete 1"
    sleep 0.1

    expect(stderr).to include "[ERROR]"
    expect(stderr).to include "Task does not exist"
  end
end
