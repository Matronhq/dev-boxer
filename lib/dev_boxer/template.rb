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
      content = render(path, vars)
      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, content)
      File.chmod(mode, output) if mode
      content
    end
  end
end
