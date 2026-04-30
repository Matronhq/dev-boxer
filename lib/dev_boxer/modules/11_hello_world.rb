module DevBoxer
  module Modules
    # Deploys a tiny local HTTP server used to verify that a Cloudflare
    # Tunnel hostname actually reaches this machine, independent of the
    # rest of the stack.
    class HelloWorld < ModuleBase
      module_name  "hello-world"
      module_order 11

      DOC_ROOT      = "/opt/dev-boxer-hello-world".freeze
      SERVICE_PATH  = "/etc/systemd/system/dev-boxer-hello-world.service".freeze

      def run
        section "Hello world smoke-test service"

        port = config.hello_world&.port || 9810
        deploy_doc_root
        deploy_unit(port)
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:enable, "dev-boxer-hello-world")
        shell.systemctl(:restart, "dev-boxer-hello-world")
        ok "Hello-world service running on http://localhost:#{port}"
      end

      private

      def deploy_doc_root
        FileUtils.mkdir_p(DOC_ROOT)
        File.chmod(0o755, DOC_ROOT)
        File.write("#{DOC_ROOT}/index.html", "Hello world\n")
      end

      def deploy_unit(port)
        File.write(SERVICE_PATH, <<~UNIT)
          [Unit]
          Description=Dev Boxer hello-world tunnel smoke test
          After=network.target

          [Service]
          Type=simple
          WorkingDirectory=#{DOC_ROOT}
          ExecStart=/usr/bin/python3 -m http.server #{port} --bind 127.0.0.1
          Restart=on-failure
          User=nobody
          Group=nogroup

          [Install]
          WantedBy=multi-user.target
        UNIT
      end
    end
  end
end
