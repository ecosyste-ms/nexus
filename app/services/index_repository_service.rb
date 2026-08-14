require 'json'
require 'open3'
require 'tempfile'

class IndexRepositoryService
  class NexusCommandError < StandardError; end

  MAX_STDERR_BYTES = 64.kilobytes

  attr_reader :repository

  def initialize(repository)
    @repository = repository
  end

  def call
    repository.mark_as_indexing!
    result = run_nexus
    package_count = repository.packages.count
    repository.mark_as_completed!(package_count: package_count)

    result.merge(success: true, package_count: package_count)
  rescue StandardError => e
    repository.reload.mark_as_failed!(e)
    raise
  end

  def run_nexus
    with_cursor_file do |cursor_path|
      run_nexus_process(nexus_command(cursor_path))
    end
  end

  def nexus_command(cursor_path = nil)
    command = [ENV.fetch('NEXUS_BINARY', 'nexus'), 'sync']
    command << '--allow-private' if ENV['NEXUS_ALLOW_PRIVATE'] == 'true'
    command.concat(['--cursor', cursor_path]) if cursor_path
    command << repository.url
    command
  end

  def with_cursor_file
    cursor = repository.nexus_cursor
    return yield unless cursor

    Tempfile.create(['nexus-cursor-', '.json']) do |file|
      file.chmod(0o600)
      file.write(JSON.generate(cursor))
      file.flush
      yield file.path
    end
  end

  def run_nexus_process(command)
    result = nil
    import_error = nil
    diagnostics = ''
    status = nil

    Open3.popen3(*command) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      stderr_thread = Thread.new { read_stderr(stderr) }

      begin
        result = NexusIndexImporter.new(repository).call(stdout)
      rescue StandardError => e
        import_error = e
        terminate_process(wait_thread)
      ensure
        stdout.close unless stdout.closed?
      end

      status = wait_thread.value
      diagnostics = stderr_thread.value
    end

    if import_error
      message = [import_error.message, diagnostics.presence].compact.join(': ')
      raise NexusCommandError, message
    end
    unless status.success?
      message = diagnostics.presence || "nexus exited with status #{status.exitstatus}"
      raise NexusCommandError, message
    end

    result
  rescue Errno::ENOENT => e
    raise NexusCommandError, "nexus executable was not found: #{e.message}"
  end

  def read_stderr(stderr)
    output = +''

    while (chunk = stderr.read(4096))
      remaining = MAX_STDERR_BYTES - output.bytesize
      output << chunk.byteslice(0, remaining) if remaining.positive?
    end

    output.strip
  rescue IOError
    output.strip
  end

  def terminate_process(wait_thread)
    return unless wait_thread.alive?

    Process.kill('TERM', wait_thread.pid)
    return if wait_thread.join(5)

    Process.kill('KILL', wait_thread.pid)
  rescue Errno::ESRCH
    nil
  end
end
