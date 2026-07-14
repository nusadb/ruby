# frozen_string_literal: true

# Booting a real NusaDB server for the test suites, from whichever source is available:
#
#   1. a `nusadb-server` binary, which is how these tests run from inside the engine workspace
#      (`cargo build -p nusadb-server`); or
#   2. the published container image, which is how they run anywhere else -- CI included, since this
#      repository ships the driver on its own and has no engine to build.
#
# Set NUSADB_SERVER_IMAGE to opt into (2), e.g.
#
#     NUSADB_SERVER_IMAGE=nusadb/nusadb:0.1.0.Beta ruby test/test.rb
#
# It is never chosen implicitly: `ruby test/test.rb` on a laptop with Docker installed should not
# quietly pull a 100 MB image nobody asked for.
#
# Each server is disposable and gets its own port, because the suites start several with different
# flags (--auth-user, for the SCRAM tests) and must not see each other's data.

require 'socket'
require 'tmpdir'
require 'fileutils'

module TestServer
  module_function

  # test/ -> ruby/ -> drivers/ -> the engine workspace, whose target/ holds the built binary.
  REPO_ROOT = File.expand_path('../../..', __dir__)

  def image
    value = ENV['NUSADB_SERVER_IMAGE']
    value && !value.empty? ? value : nil
  end

  def binary
    bases = []
    env = ENV['CARGO_TARGET_DIR']
    bases << env if env && !env.empty?
    bases << File.join(REPO_ROOT, 'target')
    names = Gem.win_platform? ? ['nusadb-server.exe'] : ['nusadb-server']
    bases.each do |base|
      %w[debug release].each do |profile|
        names.each do |name|
          path = File.join(base, profile, name)
          return path if File.exist?(path)
        end
      end
    end
    nil
  end

  # A test suite with no server to talk to skips rather than fails: this repository cannot build one.
  def available?
    !binary.nil? || !image.nil?
  end

  def unavailable_reason
    'no nusadb-server binary (run `cargo build -p nusadb-server`) and NUSADB_SERVER_IMAGE is unset'
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_ready(port, timeout)
    deadline = Time.now + timeout
    while Time.now < deadline
      begin
        TCPSocket.new('127.0.0.1', port).close
        return
      rescue SystemCallError
        sleep 0.1
      end
    end
    raise "server on port #{port} did not become ready within #{timeout}s"
  end

  # Starts a server and returns a handle to pass to .stop. +extra+ is appended to its argv, so the
  # suites can ask for a server with, say, --auth-user.
  # NUSADB_SERVER_IMAGE wins over a binary that happens to be lying around: it is set on purpose,
  # and the point of setting it is to test against that image.
  def start(*extra)
    port = free_port
    handle = image ? start_container(image, port, extra) : start_process(binary, port, extra)
    # A container has an image to pull and a runtime to start before the server even runs, so it
    # gets a longer grace period than a binary already sitting on disk.
    wait_ready(port, image ? 60 : 15)
    handle
  rescue StandardError
    stop(handle) if handle
    raise
  end

  def start_process(bin, port, extra)
    dir = Dir.mktmpdir('nusadb-ruby-')
    pid = spawn(
      { 'RUST_LOG' => 'error' },
      bin, '--listen', "127.0.0.1:#{port}", '--data-dir', dir,
      *extra,
      out: File::NULL, err: File::NULL
    )
    { mode: :process, pid: pid, port: port, dir: dir }
  end

  # The container listens on 0.0.0.0 because it has to be reachable from outside its own network
  # namespace, and is published on 127.0.0.1 only, so a test server is never exposed to the network.
  # --data-dir is the image's own default, which is the one path its unprivileged user can write to.
  def start_container(image, port, extra)
    argv = [
      'docker', 'run', '--detach', '--rm',
      '--publish', "127.0.0.1:#{port}:#{port}",
      image,
      '--listen', "0.0.0.0:#{port}", '--data-dir', '/var/lib/nusadb',
      *extra
    ]
    id = IO.popen(argv, err: %i[child out], &:read).to_s.strip
    raise "docker run failed for #{image}:\n#{id}" unless $?.success?

    { mode: :container, id: id, port: port }
  end

  def stop(handle)
    return unless handle

    case handle[:mode]
    when :process
      begin
        Process.kill('KILL', handle[:pid])
        Process.wait(handle[:pid])
      rescue Errno::ESRCH, Errno::ECHILD
        # already gone
      end
      FileUtils.remove_entry(handle[:dir]) if handle[:dir] && File.directory?(handle[:dir])
    when :container
      system('docker', 'rm', '--force', handle[:id], out: File::NULL, err: File::NULL)
    end
  end

  def with(*extra)
    handle = start(*extra)
    yield handle[:port]
  ensure
    stop(handle)
  end
end
