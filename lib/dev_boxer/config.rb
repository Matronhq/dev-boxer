require "yaml"
require "fileutils"

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

    def self.deep_merge(a, b)
      a.merge(b) do |_, av, bv|
        av.is_a?(Hash) && bv.is_a?(Hash) ? deep_merge(av, bv) : bv
      end
    end

    # Read existing YAML, deep-merge `hash` in, write back as proper YAML.
    # Use this for module-level persistence — appending duplicate top-level
    # keys silently destroys the previous section on next parse.
    def self.merge_into_file(path, hash)
      existing = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      merged = deep_merge(existing, hash)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, merged.to_yaml)
      merged
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
