require "shellwords"

module DevBoxer
  module Modules
    class Onboarding < ModuleBase
      module_name "onboarding"
      module_order 13

      def run
        section "Open your Matron"
        install_commands
        shell.sh!("/usr/local/bin/matron status")
        if interactive?
          shell.run_as_user_interactive("root", "/usr/local/bin/matron login")
          shell.run_as_user_interactive("root", "/usr/local/bin/matron link")
        else
          info "Services installed. Finish AI sign-in with: sudo matron login"
          info "Then show your sign-in QR with: sudo matron link"
        end
        info "Open #{JournalEnrollment.https_base(exposure.journal_public_url)}/app/"
        info "Click the pencil (New session), choose this box if asked, leave Folder path blank, then Start."
        info 'Send: "Say hello, then put a notice in For you saying my first chat works."'
        info "Setup is complete when you see the reply and that notice in For you."
        info "Help and recovery: https://matron.chat/getting-started/#help"
      end

      private

      def install_commands
        root = File.expand_path("../../..", __dir__)
        # The installed launcher retains the location of the checkout and
        # config without requiring the user to know either one.
        shell.write_file("/usr/local/bin/matron", <<~SH, mode: 0o755)
          #!/bin/sh
          exec ruby #{Shellwords.escape(File.join(root, "bin/matron"))} --config #{Shellwords.escape(config_path)} "$@"
        SH
      end
    end
  end
end
