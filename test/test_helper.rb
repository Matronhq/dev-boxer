require "minitest/autorun"
require "stringio"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "dev_boxer"
require_relative "support/fake_cloudflare"
