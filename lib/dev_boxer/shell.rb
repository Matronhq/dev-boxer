require "open3"
require "fileutils"
require "shellwords"

module DevBoxer
  class Shell
    Error = Class.new(StandardError)

    # On success, callers usually want to parse stdout (e.g.
    # `node --version`); merging stderr in corrupts that output when a
    # subprocess prints a deprecation notice or similar to stderr.
    # On failure, stderr usually has the relevant error message and is
    # what the operator wants to see — so `sh!` formats both into the
    # raised Error message. The runner returns [success, stdout, stderr]
    # so each consumer can pick what it needs.
    DEFAULT_RUNNER = lambda do |cmd, opts = {}|
      stdout, stderr, status = Open3.capture3("/bin/sh", "-c", cmd, stdin_data: opts[:stdin] || "")
      [status.success?, stdout, stderr]
    end

    def initialize(runner: DEFAULT_RUNNER)
      @runner = runner
    end

    def sh(cmd, **opts)
      success, _stdout, _stderr = @runner.call(cmd, opts)
      success
    end

    def sh!(cmd, **opts)
      success, stdout, stderr = @runner.call(cmd, opts)
      unless success
        # Force a newline between stdout and the stderr header so callers
        # whose stdout doesn't end in \n still get a readable separator.
        sep = stdout.end_with?("\n") || stdout.empty? ? "" : "\n"
        raise Error, "command failed: #{cmd}\n--- stdout ---\n#{stdout}#{sep}--- stderr ---\n#{stderr}"
      end
      stdout
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
