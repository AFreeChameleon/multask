require "open3"
require "support/file_helper"
require "support/process_helper"

RSpec.describe "mlt ls" do

  it "Test empty table" do
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} ls"
    table = stdout.split("\n").last 4

    expect(table[0]).not_to include " "
    expect(table[0]).to include "-"

    expect(table[1]).to include " "
    expect(table[1]).not_to include "-"
    expect(table[1]).to include "id"
    expect(table[1]).to include "namespace"
    expect(table[1]).to include "command"
    expect(table[1]).to include "location"
    expect(table[1]).to include "pid"
    expect(table[1]).to include "status"
    expect(table[1]).to include "memory"
    expect(table[1]).to include "cpu"
    expect(table[1]).to include "runtime"

    expect(table[2]).not_to include " "
    expect(table[2]).to include "-"

    expect(table[3]).not_to include " "
    expect(table[3]).to include "-"
  end

  it "Test table with multiple tasks" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} create echo hi --no-run"
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} create echo hello --no-run"
    sleep 0.1
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} ls"
    table = stdout.split("\n").last 6

    first_task = table[3].split(/[\s,|,\u0000]/).select { |el| not el.empty? }
    expect(first_task[0]).to eq "1"
    expect(first_task[1]).to eq "N/A"
    expect(first_task[2]).to eq "echo"
    expect(first_task[3]).to eq "hi"
    expect(first_task[5]).to eq "N/A"
    expect(first_task[6]).to include "Stopped"
    expect(first_task[7]).to include "N/A"
    expect(first_task[8]).to include "N/A"
    expect(first_task[9]).to include "N/A"

    second_task = table[4].split(/[\s,|,\u0000]/).select { |el| not el.empty? }
    expect(second_task[0]).to eq "2"
    expect(second_task[1]).to eq "N/A"
    expect(second_task[2]).to eq "echo"
    expect(second_task[3]).to eq "hello"
    expect(second_task[5]).to eq "N/A"
    expect(second_task[6]).to include "Stopped"
    expect(second_task[7]).to include "N/A"
    expect(second_task[8]).to include "N/A"
    expect(second_task[9]).to include "N/A"
  end

  it "Test table with running task" do
    command = FileHelpers.is_unix ? "sleep 5" : "powershell -C Start-Sleep -Seconds 5"
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} c -- #{command}"
    sleep 0.1

    running = ProcessHelpers.wait_for_task_running 1, 10

    expect(running).to be true

    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} ls"

    table = stdout.split("\n").last 5

    stop_stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} stop 1"

    table_shows_running = false

    table.each do |row|
      if row.include? "Running"
        table_shows_running = true
      end
    end

    expect(table_shows_running).to be true
    expect(stop_stdout).to include "[SUCCESS]"
    expect(stop_stdout).to include "Task stopped with id 1"
  end

  it "Test stats table" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} create -bpi echo hi --no-run"
    sleep 0.1

    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} ls -s"

    table = stdout.split("\n").last 5
    task = table[3].split(/[\s,|,\u0000]/).select { |el| not el.empty? }
    expect(task[0]).to eq "1"
    expect(task[1]).to eq "None"
    expect(task[2]).to eq "None"
    expect(task[3]).to eq "Yes"
    expect(task[4]).to eq "Yes"
    expect(task[5]).to eq "Yes"
    expect(task[6]).to include "shallow"
  end

  it "Test table with filtering multiple tasks" do
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} create echo hi --no-run"
    _, _, _ = Open3.capture3 "#{FileHelpers.get_exe} create echo hello --no-run"
    sleep 0.1
    stdout, _, _ = Open3.capture3 "#{FileHelpers.get_exe} ls 1"
    table = stdout.split("\n").last 5

    first_task = table[3].split(/[\s,|,\u0000]/).select { |el| not el.empty? }
    expect(first_task[0]).to eq "1"
    expect(first_task[1]).to eq "N/A"
    expect(first_task[2]).to eq "echo"
    expect(first_task[3]).to eq "hi"
    expect(first_task[5]).to eq "N/A"
    expect(first_task[6]).to include "Stopped"
    expect(first_task[7]).to include "N/A"
    expect(first_task[8]).to include "N/A"
    expect(first_task[9]).to include "N/A"

    expect(table[4]).not_to include "2"
  end
end
