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

    def self.render_to(path, output, vars, mode: nil)
      return render_private_to(path, output, vars, mode: mode) if mode
      content = render(path, vars)
      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, content)
      content
    end

    # For renders that carry secrets. Kept separate from render_to so a
    # secret never flows anywhere near its plain File.write.
    def self.render_private_to(path, output, vars, mode: 0o600)
      content = render(path, vars)
      FileUtils.mkdir_p(File.dirname(output))
      # The bridge .env carries HMAC_SECRET and OPENAI_API_KEY.
      SecureFile.write(output, content, mode)
      content
    end
  end
end
