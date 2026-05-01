#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "rbconfig"

ROOT = File.expand_path(__dir__)

def git_capture(*args)
  output = IO.popen(["git", "-C", ROOT, *args], err: File::NULL, &:read)
  $?.success? ? output.strip : nil
end

def git_success?(*args)
  system("git", "-C", ROOT, *args, out: File::NULL, err: File::NULL)
end

def auto_update_checkout
  return unless Process.uid.zero?
  return if ENV["DEV_BOXER_SKIP_AUTO_UPDATE"] == "1"
  return unless Dir.exist?(File.join(ROOT, ".git"))

  branch = git_capture("rev-parse", "--abbrev-ref", "HEAD")
  return if branch.nil? || branch.empty? || branch == "HEAD"

  unless git_success?("diff", "--quiet") && git_success?("diff", "--cached", "--quiet")
    warn "Dev Boxer checkout has local modifications; skipping auto-update."
    return
  end

  before = git_capture("rev-parse", "HEAD")
  return unless before

  unless git_success?("fetch", "--quiet", "origin", branch) &&
      git_success?("pull", "--ff-only", "--quiet", "origin", branch)
    warn "Could not auto-update Dev Boxer; continuing with the current checkout."
    return
  end

  after = git_capture("rev-parse", "HEAD")
  return if after.nil? || after == before

  warn "Updated Dev Boxer to #{after[0, 7]}; restarting setup."
  ENV["DEV_BOXER_SKIP_AUTO_UPDATE"] = "1"
  exec RbConfig.ruby, File.join(ROOT, "setup.rb"), *ARGV
end

auto_update_checkout

$LOAD_PATH.unshift(File.join(ROOT, "lib"))

require "dev_boxer"

DEFAULT_CONFIG = File.join(ROOT, "config.yml")

options = {
  config: DEFAULT_CONFIG,
  modules_dir: File.join(ROOT, "lib", "dev_boxer", "modules"),
  templates_dir: File.join(ROOT, "templates"),
  skip: [],
  non_interactive: false,
  reconfigure: false,
  wizard_only: false,
}
config_explicit = false

parser = OptionParser.new do |opts|
  opts.banner = "Usage: setup.rb [options]"
  opts.on("--dry-run",        "List modules without running them")           { options[:dry_run] = true }
  opts.on("--only NAME",      "Run only this module")                        { |v| options[:only] = v }
  opts.on("--from NAME",      "Start from this module and run subsequent")   { |v| options[:from] = v }
  opts.on("--skip NAME",      "Skip this module (repeatable)")               { |v| options[:skip] << v }
  opts.on("--config PATH",    "Path to config.yml (default: ./config.yml)")  { |v| options[:config] = v; config_explicit = true }
  opts.on("--modules-dir DIR","Path to modules directory")                   { |v| options[:modules_dir] = v }
  opts.on("--templates-dir DIR","Path to templates directory")               { |v| options[:templates_dir] = v }
  opts.on("--wizard-only",    "Run first-run setup wizard, then exit")       { options[:wizard_only] = true }
  opts.on("--reconfigure",    "Force the setup wizard before running")       { options[:reconfigure] = true }
  opts.on("--non-interactive","Fail instead of prompting for config")        { options[:non_interactive] = true }
  opts.on("-h", "--help",     "Show this help")                              { puts opts; exit 0 }
end

begin
  parser.parse!
rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
  warn e.message
  warn parser
  exit 2
end

log = DevBoxer::Log.new

interactive = $stdin.tty? && $stdout.tty?

run_wizard = lambda do |force: false|
  if options[:non_interactive] || !interactive
    warn "Config file is missing or incomplete: #{options[:config]}"
    warn "Run setup interactively first, or create config.yml and secrets.yml manually."
    exit 2
  end
  DevBoxer::Wizard.run(config_path: options[:config], force: force)
end

load_config = lambda do
  DevBoxer::Config.load(options[:config])
end

if options[:wizard_only]
  run_wizard.call(force: options[:reconfigure])
  begin
    DevBoxer::Config.validate!(load_config.call)
  rescue DevBoxer::Config::Invalid => e
    warn e.message
    exit 2
  end
  exit 0
end

run_wizard.call(force: true) if options[:reconfigure]

config =
  if File.exist?(options[:config])
    load_config.call
  elsif config_explicit
    warn "Config file not found: #{options[:config]}"
    exit 2
  else
    run_wizard.call
    load_config.call
  end

unless options[:dry_run]
  errors = DevBoxer::Config.validation_errors(config)
  unless errors.empty?
    if options[:non_interactive] || !interactive
      warn "Config is incomplete:"
      errors.each { |error| warn "- #{error}" }
      exit 2
    end

    warn "Config is incomplete; starting first-run setup."
    run_wizard.call(force: true)
    config = load_config.call

    begin
      DevBoxer::Config.validate!(config)
    rescue DevBoxer::Config::Invalid => e
      warn e.message
      exit 2
    end
  end
end

mods   = DevBoxer::Modules.discover(options[:modules_dir])
runner = DevBoxer::Runner.new(
  modules: mods,
  config: config,
  log: log,
  templates_dir: options[:templates_dir],
  config_path: options[:config],
  secrets_path: DevBoxer::Config.secrets_path_for(options[:config]),
)

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
