module DevBoxer
  module Modules
    # Thin shell around the Exposure strategy (lib/dev_boxer/exposure/).
    # All mode-specific behavior lives in the strategies.
    class Exposure < ModuleBase
      module_name  "exposure"
      module_order 9

      def run
        section "Exposure"
        exposure.setup!
        # The full connection summary (URLs, Access, self-signed fingerprint)
        # is printed once at the very end of the run by the hello-world module,
        # the last to run. setup! already logs its own completion line here.
      end
    end
  end
end
