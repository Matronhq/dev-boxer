require_relative "section"

module DevBoxer
  class Wizard
    # Keys the wizard writes without prompting: desktop/docker defaults and
    # the hello-world smoke-test port. TITLE is nil — no numbered header.
    class MachineDefaultsSection < Section
      DEFAULT_HELLO_WORLD_PORT = 9820

      def self.owned_keys = %w[desktop docker hello_world]

      def self.validate(hash, errors)
        errors << "hello_world.port is required" if Config.blank?(hash.dig("hello_world", "port"))
        Config.validate_port(errors, "hello_world.port", hash.dig("hello_world", "port"))
      end

      def collect(_so_far)
        [{
          "desktop" => { "enabled" => false },
          "docker" => {
            "data_root" => nil,
            "containerd_root" => nil,
            "prune" => { "interval" => "2h", "keep_until" => "4h" },
          },
          "hello_world" => {
            "port" => existing.dig("hello_world", "port") || DEFAULT_HELLO_WORLD_PORT,
          },
        }, {}]
      end
    end
  end
end
