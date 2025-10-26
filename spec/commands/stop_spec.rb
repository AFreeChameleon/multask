require "open3"
require "support/file_helper"
require "support/process_helper"

RSpec.describe "mlt stop" do
  it "Test stopping persisting task" do
    command = FileHelpers.is_unix ? "sleep 5" : "powershell -C Start-Sleep -Seconds 5"
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c -- #{command}"
    ProcessHelpers.wait_for_task_running 1, 5
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} stop 1"

    running = ProcessHelpers.wait_for_task_running 1, 5
    expect(running).to be false
  end

  it "Test stopping already stopped task" do
    command = FileHelpers.is_unix ? "sleep 5" : "powershell -C Start-Sleep -Seconds 5"
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c -- #{command}"

    ProcessHelpers.wait_for_task_running 1, 5

    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} stop 1"
    sleep 0.1
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} stop 1"
    sleep 0.1

    expect(stdout).to include "Task 1 is not running"
  end

  it "Test stopping task that doesn't exist" do
    _, stderr, _ = Open3.capture3 "#{FileHelpers.get_exe} s 1"
    sleep 0.1

    expect(stderr).to include "[ERROR]"
    expect(stderr).to include "Task does not exist"
  end
end
