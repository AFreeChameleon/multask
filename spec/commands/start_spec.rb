require "open3"
require "support/file_helper"
require "support/process_helper"

RSpec.describe "mlt start" do
  it "Test starting simple task" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi --no-run"
    sleep 0.1
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} s 1"
    sleep 0.1

    expect(stdout).to include "[SUCCESS]"
    expect(stdout).to include "Task started with id 1."

    logs = FileHelpers.read_task_logs_stdout 1

    expect(logs).to include "hi"
  end

  it "Test starting persisting task" do
    command = FileHelpers.is_unix ? "sleep 5" : "powershell -C Start-Sleep -Seconds 5"
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c --no-run -- #{command}"
    sleep 0.1
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} start 1"

    running = ProcessHelpers.wait_for_task_running 1, 5


    expect(running).to be true
  end

  it "Test starting task with all flags" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi --no-run"
    sleep 0.1
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} s 1 -m 20M -c 20 -i -p -s deep"
    sleep 0.1

    stats = FileHelpers.read_task_stats 1

    expect(stats["command"]).to eq "echo hi"
    expect(stats["memory_limit"]).to eq 20000000
    expect(stats["cpu_limit"]).to eq 20
    expect(stats["persist"]).to be true
    expect(stats["monitoring"]).to eq "Deep"
    expect(stats["boot"]).to be false
    expect(stats["interactive"]).to be true
  end

  it "Test starting task that's already running" do
    command = FileHelpers.is_unix ? "sleep 5" : "powershell -C Start-Sleep -Seconds 5"
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c --no-run -- #{command}"
    sleep 0.1
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} s 1"
    sleep 0.1

    running = ProcessHelpers.wait_for_task_running 1, 5
    expect(running).to be true

    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} s 1"
    sleep 0.1

    expect(stdout).to include "Task 1 is already running"
  end

  it "Test starting task updating environment variables" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi --no-run"
    sleep 0.1

    ENV["NEW_ENV"] = "NEW_ENV_VALUE"

    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} s 1 -e"
    sleep 0.1

    env = FileHelpers.read_task_env 1

    expect(env["map_string"]).to include "NEW_ENV=NEW_ENV_VALUE"
  end

  it "Test starting task that doesn't exist" do
    _, stderr, _ = Open3.capture3 "#{FileHelpers.get_exe} s 1"
    sleep 0.1

    expect(stderr).to include "[ERROR]"
    expect(stderr).to include "Task does not exist"
  end
end
