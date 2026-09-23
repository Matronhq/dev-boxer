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
      write_restricted(output, content, mode)
      content
    end

    # A mode is only ever passed to protect secrets (the bridge .env carries
    # HMAC_SECRET and OPENAI_API_KEY). File.write + chmod would create the
    # file at the umask default (usually 0644) and leave the secret readable
    # until the chmod; re-rendering would write it into an existing wider
    # file the same way. Instead create a fresh file at the target mode, fill
    # it, and rename it over the output, so the content is never in a file
    # anyone else can open.
    def self.write_restricted(output, content, mode)
      tmp = "#{output}.tmp-#{Process.pid}"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, mode) do |f|
        f.chmod(mode) # open's perm is masked by umask; pin it exactly
        f.write(content)
      end
      File.rename(tmp, output)
    rescue StandardError
      File.unlink(tmp) if tmp && File.exist?(tmp)
      raise
    end
    private_class_method :write_restricted
  end
end
