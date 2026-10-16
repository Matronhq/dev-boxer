module DevBoxer
  VERSION = "0.1.0"

  # A setup step failed for a reason the operator can fix. setup.rb prints
  # the message (which says what to do next) without a backtrace.
  class SetupError < StandardError; end
end

require_relative "dev_boxer/log"
require_relative "dev_boxer/config"
require_relative "dev_boxer/cloudflare_api"
require_relative "dev_boxer/cloudflare_token_check"
require_relative "dev_boxer/ssh_key_check"
require_relative "dev_boxer/journal_enrollment"
require_relative "dev_boxer/secure_file"
require_relative "dev_boxer/shell"
require_relative "dev_boxer/template"
require_relative "dev_boxer/exposure"
require_relative "dev_boxer/wizard"
require_relative "dev_boxer/module_base"
require_relative "dev_boxer/modules"
require_relative "dev_boxer/runner"
