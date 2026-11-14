require "json"
require "shellwords"

module DevBoxer
  module Components
    def self.tool_version(name)
      version = JSON.parse(File.read(File.expand_path("../../components.json", __dir__))).fetch("tools").fetch(name)
      raise SetupError, "Invalid tool version" unless version.match?(/\A\d+\.\d+\.\d+\z/)
      version
    end

    def self.checkout(name, path, owner:, shell:)
      entry = JSON.parse(File.read(File.expand_path("../../components.json", __dir__))).fetch(name)
      revision = entry.fetch("revision")
      raise SetupError, "Invalid component revision" unless revision.match?(/\A[0-9a-f]{40}\z/)
      dir = Shellwords.escape(path)
      # The journal is a system account with /usr/sbin/nologin, so `su -`
      # cannot run its install commands.
      run = ->(cmd) { shell.sh!("runuser -u #{Shellwords.escape(owner)} -- sh -c #{Shellwords.escape(cmd)}") }
      unless Dir.exist?(File.join(path, ".git"))
        run.call("git clone --depth 1 #{Shellwords.escape(entry.fetch('repo'))} #{dir}")
      end
      run.call("git -C #{dir} diff --quiet && git -C #{dir} diff --cached --quiet")
      run.call("git -C #{dir} fetch --depth 1 origin #{revision}")
      run.call("git -C #{dir} checkout --detach #{revision}")
    end
  end
end
