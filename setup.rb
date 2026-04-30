#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

ROOT = File.expand_path(__dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

require "dev_boxer"

options = {
  config: File.join(ROOT, "config.yml"),
  modules_dir: File.join(ROOT, "lib", "dev_boxer", "modules"),
  skip: [],
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: setup.rb [options]"
  opts.on("--dry-run",        "List modules without running them")           { options[:dry_run] = true }
  opts.on("--only NAME",      "Run only this module")                        { |v| options[:only] = v }
  opts.on("--from NAME",      "Start from this module and run subsequent")   { |v| options[:from] = v }
  opts.on("--skip NAME",      "Skip this module (repeatable)")               { |v| options[:skip] << v }
  opts.on("--config PATH",    "Path to config.yml (default: ./config.yml)")  { |v| options[:config] = v }
  opts.on("--modules-dir DIR","Path to modules directory")                   { |v| options[:modules_dir] = v }
  opts.on("-h", "--help",     "Show this help")                              { puts opts; exit 0 }
end

begin
  parser.parse!
rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
  warn e.message
  warn parser
  exit 2
end

log    = DevBoxer::Log.new
config = File.exist?(options[:config]) ? DevBoxer::Config.load(options[:config]) : DevBoxer::Config.from_hash({})
mods   = DevBoxer::Modules.discover(options[:modules_dir])
runner = DevBoxer::Runner.new(modules: mods, config: config, log: log)

begin
  runner.run(
    only:    options[:only],
    from:    options[:from],
    skip:    options[:skip],
    dry_run: options[:dry_run],
  )
rescue DevBoxer::Runner::UnknownModule => e
  warn e.message
  exit 1
end
