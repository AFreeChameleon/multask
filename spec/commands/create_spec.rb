require "open3"
require "support/file_helper"
require "support/process_helper"

RSpec.describe "mlt create" do

  it "Testing simple command" do
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} create echo hi"
    sleep 0.1

    stats = FileHelpers.read_task_stats 1

    expect(stdout).to include "[SUCCESS]"
    expect(stdout).to include "Task created with id 1"

    expect(stats["command"]).to eq "echo hi"
    expect(stats["memory_limit"]).to eq 0
    expect(stats["cpu_limit"]).to eq 0
    expect(stats["persist"]).to be false
    expect(stats["monitoring"]).to eq "Shallow"
    expect(stats["boot"]).to be false
    expect(stats["interactive"]).to be false
  end

  it "Testing simple abbreviated command" do
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi"

    expect(stdout).to include "[SUCCESS]"
    expect(stdout).to include "Task created with id 1"
  end

  it "Testing multiple tasks creating" do
    stdout1, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi"
    stdout2, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c echo hi"

    expect(stdout1).to include "[SUCCESS]"
    expect(stdout1).to include "Task created with id 1"
    expect(stdout2).to include "[SUCCESS]"
    expect(stdout2).to include "Task created with id 2"
  end

  it "Testing command with all flags enabled" do
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} create -c 20 -m 20M echo hi -bpi -s deep"
    sleep 0.1

    expect(stdout).to include "[SUCCESS]"
    expect(stdout).to include "Task created with id 1"

    stats = FileHelpers.read_task_stats 1

    expect(stats["command"]).to eq "echo hi"
    expect(stats["memory_limit"]).to eq 20000000
    expect(stats["cpu_limit"]).to eq 20
    expect(stats["persist"]).to be true
    expect(stats["monitoring"]).to eq "Deep"
    expect(stats["boot"]).to be true
    expect(stats["interactive"]).to be true
  end

  it "Testing command with invalid flag" do
    _, stderr, _ = Open3.capture3 "#{FileHelpers.get_exe} create -z"
    sleep 0.1

    expect{FileHelpers.read_task_stats 1}.to raise_error Errno::ENOENT
    expect(stderr).to include "[ERROR]"
    expect(stderr).to include "One or more options are invalid."
  end

  it "Testing command with flag with missing value" do
    _, stderr, _ = Open3.capture3 "#{FileHelpers.get_exe} create -c"
    sleep 0.1

    expect{FileHelpers.read_task_stats 1}.to raise_error Errno::ENOENT
    expect(stderr).to include "[ERROR]"
    expect(stderr).to include "One or more arguments are missing its value."
  end

  it "Testing command that persists" do
    command = FileHelpers.is_unix ? "sleep 5" : "powershell -C Start-Sleep -Seconds 5"
    create_stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} create -- #{command}"

    running = ProcessHelpers.wait_for_task_running 1, 5
    expect(running).to be true

    stop_stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} stop 1"

    expect(create_stdout).to include "[SUCCESS]"
    expect(create_stdout).to include "Task created with id 1"

    expect(stop_stdout).to include "[SUCCESS]"
    expect(stop_stdout).to include "Task stopped with id 1"
  end
end
