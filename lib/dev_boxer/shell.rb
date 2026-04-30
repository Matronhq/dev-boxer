require "open3"
require "fileutils"
require "shellwords"

module DevBoxer
  class Shell
    Error = Class.new(StandardError)

    DEFAULT_RUNNER = lambda do |cmd, opts = {}|
      stdout, stderr, status = Open3.capture3(cmd, stdin_data: opts[:stdin] || "")
      [status.success?, stdout + stderr]
    end

    def initialize(runner: DEFAULT_RUNNER)
      @runner = runner
    end

    def sh(cmd, **opts)
      success, _ = @runner.call(cmd, opts)
      success
    end

    def sh!(cmd, **opts)
      success, output = @runner.call(cmd, opts)
      raise Error, "command failed: #{cmd}\n#{output}" unless success
      output
    end

    def command_exists?(name)
      sh("command -v #{Shellwords.escape(name)} >/dev/null 2>&1")
    end

    def apt_installed?(pkg)
      sh("dpkg -s #{Shellwords.escape(pkg)} >/dev/null 2>&1")
    end

    def apt_install(*pkgs)
      return if pkgs.empty?
      # Always invoke apt-get install — apt is itself idempotent for already-
      # installed-and-current packages and it correctly handles version
      # upgrades when a newer version is in repos (e.g. after a NodeSource
      # repo swap from v18 → v20). The previous skip-if-installed
      # short-circuit silently prevented those upgrades.
      sh!("DEBIAN_FRONTEND=noninteractive apt-get install -y -qq #{pkgs.map { |p| Shellwords.escape(p) }.join(' ')}")
    end

    def apt_update
      sh!("apt-get update -qq")
    end

    def service_active?(name)
      sh("systemctl is-active --quiet #{Shellwords.escape(name)}")
    end

    def systemctl(action, name)
      sh!("systemctl #{action} #{Shellwords.escape(name)}")
    end

    def run_as_user(user, cmd)
      sh!("su - #{Shellwords.escape(user)} -c #{Shellwords.escape(cmd)}")
    end

    def write_file(path, content, mode: nil, owner: nil)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      File.chmod(mode, path) if mode
      sh!("chown #{Shellwords.escape(owner)} #{Shellwords.escape(path)}") if owner
    end

    def user_exists?(user)
      sh("id -u #{Shellwords.escape(user)} >/dev/null 2>&1")
    end

    def wait_for_url(url, timeout: 30)
      timeout.times do
        return true if sh("curl -sf #{Shellwords.escape(url)} >/dev/null 2>&1")
        sleep 1
      end
      false
    end
  end
end
