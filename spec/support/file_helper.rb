require "fileutils"
require "json"

module FileHelpers

  def self.is_unix
    # linux -> x86_64-linux
    # macos -> arm64-darwin23
    # windows -> tbd
    RUBY_PLATFORM.include? "linux" or RUBY_PLATFORM.include? "darwin"
  end

  def self.get_exe
    if is_unix
      "./zig-out/bin/mlt"
    else
      ".\\zig-out\\bin\\mlt.exe"
    end
  end

  def self.get_home
    home = is_unix ? ENV["HOME"] : ENV["USERPROFILE"]
    home
  end

  def self.build_mlt
    puts "Building mlt executable..."
    output = `zig build -Doptimize=ReleaseSmall`
    output
  end

  def self.reset
    dir = Pathname.new(File.join(get_home, ".multi-tasker")).cleanpath.to_path.tr('/', '\\')
    if File.directory? dir.to_s
      sleep 0.1
      FileUtils.rm_rf dir, :secure => true
    end
    check_multi_tasker_dir_missing
    sleep 0.5
  end

  def self.check_multi_tasker_dir_missing
    dir = File.join get_home, ".multi-tasker"
    (0..5).each do
      if not File.directory? dir.to_s
        return nil
      end
      sleep 0.5
    end
    nil
  end

  def self.read_task_stats id
    file = File.join get_home, ".multi-tasker", "tasks", id.to_s, "stats.json"
    content = File.read file
    json_content = JSON.parse content
    json_content
  end

  def self.remove_task_processes id
      path = File.join get_home, ".multi-tasker", "tasks", id.to_s, "processes.json"
      file = File.write path, ""
      FileUtils.rm_f file.to_s
  end

  def self.read_task_processes id, retries
    retries.times do |i|
      begin
        file = File.join get_home, ".multi-tasker", "tasks", id.to_s, "processes.json"
        content = File.read file
        json_content = JSON.parse content
        return json_content
      rescue
        if i == retries - 1
          break
        end
        sleep 1
      end
    end
    return nil
  end

  def self.delete_task_stats id
    file = File.join get_home, ".multi-tasker", "tasks", id.to_s, "stats.json"
    File.delete file
  end

  def self.read_task_logs_stdout id
    file = File.join get_home, ".multi-tasker", "tasks", id.to_s, "stdout"
    content = File.read file
    content
  end

  def self.read_task_logs_stderr id
    file = File.join get_home, ".multi-tasker", "tasks", id.to_s, "stderr"
    content = File.read file
    content
  end

  def self.read_task_env id
    file = File.join get_home, ".multi-tasker", "tasks", id.to_s, "env.json"
    content = File.read file
    json_content = JSON.parse content
    json_content
  end

  # Returns true if process changed, false if it didn't
  def self.wait_for_task_process_change id, retries
    procs = read_task_processes id, 1
    task_pid = procs["task"]["pid"]
    retries.times do
      new_procs = read_task_processes id, 1
      new_task_id = new_procs["task"]["pid"]
      if task_pid != new_task_id
        return true
      end
      sleep 1
    end
    return false
  end
end
