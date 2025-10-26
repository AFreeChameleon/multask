
module ProcessHelpers

  def self.proc_running pid
    begin
      not (Process.kill 0, pid).zero?
    rescue => e
      false
    end
  end

  def self.task_running id
    procs = FileHelpers.read_task_processes id, 1
    if proc_running procs["pid"]
      return true
    end
    if proc_running procs["task"]["pid"]
      return true
    end

    procs["children"].each do |child|
      if proc_running child["pid"]
        return true
      end
    end
    false
  end

  def self.wait_for_task_running id, retries
    sleep 0.1
    retries.times do
      begin
        running = task_running id
        if running
          return true
        end
        sleep 1
      rescue
        sleep 1
      end
    end
    false
  end
end
