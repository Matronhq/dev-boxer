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
        exposure.summary_lines.each { |line| info line }
      end
    end
  end
end
