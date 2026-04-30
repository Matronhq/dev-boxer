require "yaml"

module DevBoxer
  class Config
    NotFound = Class.new(StandardError)

    def self.load(path)
      raise NotFound, "Config not found: #{path}" unless File.exist?(path)
      from_hash(YAML.safe_load_file(path) || {})
    end

    def self.from_hash(hash)
      new(hash)
    end

    def initialize(hash)
      @hash = hash || {}
    end

    def to_h
      @hash
    end

    def [](key)
      wrap(@hash[key.to_s])
    end

    def respond_to_missing?(name, _include_private = false)
      true
    end

    def method_missing(name, *args, &block)
      return super unless args.empty? && !block
      wrap(@hash[name.to_s])
    end

    private

    def wrap(value)
      case value
      when Hash then Config.new(value)
      else value
      end
    end
  end
end
