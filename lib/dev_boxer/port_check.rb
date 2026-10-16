require "shellwords"

module DevBoxer
  # The TCP ports setup makes services listen on, checked before any step
  # runs: two services set to the same port, or a port already held by some
  # other program, would otherwise fail late (sshd or nginx refusing to
  # start) or, for SSH, after the firewall has already moved.
  module PortCheck
    # One planned listener. modules: the steps that set it up (and so need
    # it free). owners: process names that mean "already ours"
    # on a re-run (ss reports the process name, at most 15 characters).
    Port = Struct.new(:number, :service, :config_key, :modules, :owners, keyword_init: true)

    NODE = %w[node nodejs npm npx tsx].freeze

    def self.planned(config)
      ports = [
        Port.new(number: port(config.ssh&.port, 2222), service: "SSH", config_key: "ssh.port",
                 modules: %w[security users], owners: %w[sshd systemd]),
        Port.new(number: 9802, service: "the Matron bridge API", modules: %w[matron], owners: NODE),
        Port.new(number: 9803, service: "the Matron file viewer", modules: %w[matron], owners: NODE),
        Port.new(number: port(config.hello_world&.port, 9820), service: "the hello-world test page",
                 config_key: "hello_world.port", modules: %w[hello-world], owners: %w[python3 python]),
      ]
      bundled = (config.journal&.mode || "bundled") == "bundled"
      ports << Port.new(number: 9810, service: "the Matron journal", modules: %w[matron], owners: NODE) if bundled
      if config.exposure&.mode == "ip"
        ip = config.exposure&.ip
        ports << Port.new(number: port(ip&.journal_port, 8443), service: "the journal over HTTPS",
                          config_key: "exposure.ip.journal_port", modules: %w[exposure], owners: %w[nginx]) if bundled
        ports << Port.new(number: port(ip&.viewer_port, 8444), service: "the file viewer over HTTPS",
                          config_key: "exposure.ip.viewer_port", modules: %w[exposure], owners: %w[nginx])
        ports << Port.new(number: port(ip&.hello_port, 8445), service: "the hello-world page over HTTPS",
                          config_key: "exposure.ip.hello_port", modules: %w[exposure], owners: %w[nginx])
      end
      if config.desktop&.enabled == true
        ports << Port.new(number: 3389, service: "remote desktop (XRDP)", modules: %w[desktop],
                          owners: %w[xrdp xrdp-sesman])
      end
      ports
    end

    # Messages for ports set to the same number by two services.
    def self.clashes(config)
      planned(config).group_by(&:number).values.select { |group| group.length > 1 }.map do |group|
        names = group.map { |entry| entry.config_key ? "#{entry.service} (#{entry.config_key})" : "#{entry.service} (fixed)" }
        "#{names.join(" and ")} are both set to port #{group.first.number}"
      end
    end

    # Messages for planned ports, of the given modules, that some other
    # program already listens on. A port held by the service itself (a
    # re-run) is fine.
    def self.busy(config, shell, module_names:)
      planned(config).select { |entry| (entry.modules & module_names).any? }.filter_map do |entry|
        holders = listeners(shell, entry.number)
        # Without root, ss cannot name the holder; don't guess.
        next if holders.nil? || holders.empty? || (holders & entry.owners).any?

        "port #{entry.number}, wanted for #{entry.service}, is already in use by #{holders.join(", ")}"
      end
    end

    # nil when nothing listens on the port (or ss is unavailable),
    # otherwise the listening process names (empty when ss cannot tell).
    def self.listeners(shell, number)
      output = shell.sh!("ss -ltnpH #{Shellwords.escape("sport = :#{number}")}").to_s
      return nil if output.strip.empty?

      output.scan(/\("([^"]+)",pid=/).flatten.uniq
    rescue Shell::Error
      nil
    end

    def self.port(value, default)
      Integer(value || default)
    rescue ArgumentError, TypeError
      default
    end
  end
end
