require "open3"
require "support/file_helper"
require "support/process_helper"

RSpec.describe "mlt edit" do

  it "Edit one task and enabling all flags" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} create echo hi --no-run"
    sleep 0.1

    original_stats = FileHelpers.read_task_stats 1
    expect(original_stats["command"]).to eq "echo hi"
    expect(original_stats["memory_limit"]).to eq 0
    expect(original_stats["cpu_limit"]).to eq 0
    expect(original_stats["persist"]).to be false
    expect(original_stats["monitoring"]).to eq "Shallow"
    expect(original_stats["boot"]).to be false
    expect(original_stats["interactive"]).to be false

    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} edit 1 -bpi -c 20 -m 20M -s deep --comm \"echo hello\""
    sleep 0.1

    new_stats = FileHelpers.read_task_stats 1

    expect(new_stats["command"]).to eq "echo hello"
    expect(new_stats["memory_limit"]).to eq 20000000
    expect(new_stats["cpu_limit"]).to eq 20
    expect(new_stats["persist"]).to be true
    expect(new_stats["monitoring"]).to eq "Deep"
    expect(new_stats["boot"]).to be true
    expect(new_stats["interactive"]).to be true
  end

  it "Edit one task and disabling all flags" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} create echo hi --no-run -bpi -c 20 -m 20M -s deep"
    sleep 0.1

    original_stats = FileHelpers.read_task_stats 1
    expect(original_stats["command"]).to eq "echo hi"
    expect(original_stats["memory_limit"]).to eq 20000000
    expect(original_stats["cpu_limit"]).to eq 20
    expect(original_stats["persist"]).to be true
    expect(original_stats["monitoring"]).to eq "Deep"
    expect(original_stats["boot"]).to be true
    expect(original_stats["interactive"]).to be true

    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} edit 1 -BPI -c none -m none -s shallow"
    sleep 0.1

    new_stats = FileHelpers.read_task_stats 1

    expect(new_stats["command"]).to eq "echo hi"
    expect(new_stats["memory_limit"]).to eq 0
    expect(new_stats["cpu_limit"]).to eq 0
    expect(new_stats["persist"]).to be false
    expect(new_stats["monitoring"]).to eq "Shallow"
    expect(new_stats["boot"]).to be false
    expect(new_stats["interactive"]).to be false
  end

  it "Test editing task that doesn't exist" do
    _, stderr, _ = Open3.capture3 "#{FileHelpers.get_exe} e 1"
    sleep 0.1

    expect(stderr).to include "[ERROR]"
    expect(stderr).to include "Task does not exist"
  end
end
