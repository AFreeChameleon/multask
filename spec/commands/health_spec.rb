require "open3"
require "support/file_helper"
require "support/process_helper"

RSpec.describe "mlt health" do
  it "Test healthy task" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi --no-run"
    sleep 0.1
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} health"

    expect(stdout).to include "Testing item: 1"
    expect(stdout).to include "Found inner item: resources.json"
    expect(stdout).to include "Found inner item: stats.json"
    expect(stdout).to include "Found inner item: processes.json"
    expect(stdout).to include "Found inner item: env.json"
    expect(stdout).to include "Found inner item: stdout"
    expect(stdout).to include "Found inner item: stderr"

    expect(stdout).to include "Namespaces are healthy"
    expect(stdout).to include "Task 1 is healthy"
  end

  it "Test unhealthy task" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi --no-run"
    sleep 0.1

    FileHelpers.delete_task_stats 1

    stdout, stderr, _ = Open3.capture3 "#{FileHelpers.get_exe} health"


    expect(stdout).to include "Testing item: 1"
    expect(stdout).to include "Found inner item: resources.json"
    expect(stderr).to include "Missing essential file `stats.json` in task dir"
    expect(stdout).to include "Found inner item: processes.json"
    expect(stdout).to include "Found inner item: env.json"
    expect(stdout).to include "Found inner item: stdout"
    expect(stdout).to include "Found inner item: stderr"

    expect(stdout).to include "Namespaces are healthy"
    expect(stderr).to include "Cannot get task with id: 1"
    expect(stderr).to include "Task file not found"
  end

  it "Test healthy and unhealthy task" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi --no-run"
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi --no-run"
    sleep 0.1

    FileHelpers.delete_task_stats 1

    stdout, stderr, _ = Open3.capture3 "#{FileHelpers.get_exe} health"

    expect(stdout).to include "Testing item: 1"
    expect(stdout).to include "Testing item: 2"
    expect(stdout).to include "Found inner item: resources.json"
    expect(stderr).to include "Missing essential file `stats.json` in task dir"
    expect(stdout).to include "Found inner item: processes.json"
    expect(stdout).to include "Found inner item: env.json"
    expect(stdout).to include "Found inner item: stdout"
    expect(stdout).to include "Found inner item: stderr"

    expect(stdout).to include "Namespaces are healthy"
    expect(stderr).to include "Cannot get task with id: 1"
    expect(stderr).to include "Task file not found"

    expect(stdout).to include "Task 2 is healthy"
  end
end

