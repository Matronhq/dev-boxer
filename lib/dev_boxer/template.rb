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

    # A caller that asks for a mode gets SecureFile, which creates the file at
    # that mode instead of writing first and tightening after. matron-bridge.env
    # carries HMAC_SECRET and is rendered with mode 0o600; a plain File.write
    # would expose it at the umask default on a first run, and at whatever the
    # existing file's mode happens to be on every run after that.
    def self.render_to(path, output, vars, mode: nil)
      content = render(path, vars)
      if mode
        SecureFile.write(output, content, mode)
      else
        FileUtils.mkdir_p(File.dirname(output))
        File.write(output, content)
      end
      content
    end
  end
end
