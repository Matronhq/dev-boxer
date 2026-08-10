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
      # repo swap from v20 -> v22). The previous skip-if-installed
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

    # Like run_as_user, but inherits the operator's stdin/stdout/stderr instead
    # of capturing them. Required for subprocesses the operator must interact
    # with (e.g. `gh auth login --web`, which prints a one-time code and waits
    # for the operator to authorize via a browser).
    def run_as_user_interactive(user, cmd)
      ok = system("su", "-", user, "-c", cmd)
      return if ok
      raise Error, "interactive command failed: su - #{user} -c #{cmd}"
    end

    # Same rule as Template.render_to: /etc/postfix/sasl_passwd is written
    # here with mode 0o600 and holds the Resend API key, so it must never
    # exist at a broader mode — not on creation, and not because an earlier
    # run left the target at 0644.
    def write_file(path, content, mode: nil, owner: nil)
      if mode
        SecureFile.write(path, content, mode)
      else
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
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

    # Like wait_for_url, but accepts ANY HTTP status — for endpoints that
    # are up-but-authenticated (matron-journal's /metrics 401s without a
    # token). curl without -f exits 0 on any HTTP response.
    def wait_for_http(url, timeout: 30)
      timeout.times do
        return true if sh("curl -s -o /dev/null #{Shellwords.escape(url)}")
        sleep 1
      end
      false
    end
  end
end
