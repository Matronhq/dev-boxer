require "fileutils"

module DevBoxer
  module Template
    NotFound = Class.new(StandardError)
    PLACEHOLDER = /\{\{([A-Z_][A-Z0-9_]*)\}\}/.freeze

    def self.render(path, vars)
      raise NotFound, "Template not found: #{path}" unless File.exist?(path)
      content = File.read(path)
      content.gsub(PLACEHOLDER) { vars[$1].to_s }
    end

    # Tighten umask before File.write so a secret-bearing render is never
    # briefly world-readable between create-time (default umask, 0o644) and
    # File.chmod. matron-bridge.env carries HMAC_SECRET and is rendered with
    # mode 0o600; without this the secret exists at 0644 for the width of
    # those two calls, and permanently if the run dies between them.
    def self.render_to(path, output, vars, mode: nil)
      content = render(path, vars)
      FileUtils.mkdir_p(File.dirname(output))
      old_umask = mode == 0o600 ? File.umask(0o077) : nil
      begin
        File.write(output, content)
      ensure
        File.umask(old_umask) if old_umask
      end
      File.chmod(mode, output) if mode
      content
    end
  end
end
