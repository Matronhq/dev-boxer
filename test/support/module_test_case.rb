require "tmpdir"
require "fileutils"

module DevBoxer
  module Testing
    class ModuleTestCase < Minitest::Test
      TEMPLATES_DIR = File.expand_path("../../templates", __dir__)

      def self.test_order = :alpha

      def setup
        @recorded = []
        @responses = {}
        @default_response = [true, ""]
        @runner = lambda do |cmd, _opts = {}|
          @recorded << cmd
          @responses.fetch(cmd, @default_response)
        end
        @shell = DevBoxer::Shell.new(runner: @runner)
        @log_io = StringIO.new
        @log = DevBoxer::Log.new(io: @log_io, color: false)
      end

      def respond(cmd, success:, output: "")
        @responses[cmd] = [success, output]
      end

      def respond_default(success:, output: "")
        @default_response = [success, output]
      end

      def build_module(klass, config_hash = {}, templates_dir: TEMPLATES_DIR)
        klass.new(
          config: DevBoxer::Config.from_hash(config_hash),
          log: @log,
          shell: @shell,
          templates_dir: templates_dir,
        )
      end

      def with_tmp_etc
        Dir.mktmpdir do |dir|
          yield dir
        end
      end

      def assert_recorded(pattern, msg = nil)
        msg ||= "expected a recorded command matching #{pattern.inspect}\nrecorded:\n#{@recorded.join("\n")}"
        assert(@recorded.any? { |c| pattern === c }, msg)
      end

      def refute_recorded(pattern, msg = nil)
        msg ||= "expected no recorded command matching #{pattern.inspect}\nrecorded:\n#{@recorded.join("\n")}"
        refute(@recorded.any? { |c| pattern === c }, msg)
      end
    end
  end
end
