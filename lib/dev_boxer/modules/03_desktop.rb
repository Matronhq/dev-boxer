module DevBoxer
  module Modules
    class Desktop < ModuleBase
      module_name  "desktop"
      module_order 3

      XFWM4_XML = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <channel name="xfwm4" version="1.0">
          <property name="general" type="empty">
            <property name="use_compositing" type="bool" value="false"/>
            <property name="theme" type="string" value="Arc-Dark"/>
          </property>
        </channel>
      XML

      def run
        section "Desktop environment"
        install_xfce
        configure_xfwm
        install_xrdp
        ok "Desktop environment setup complete"
        info "Access via SSH tunnel: ssh -L 3389:localhost:3389 #{username}@<server-ip> -p #{ssh_port}"
      end

      private

      def username = config.user.name
      def ssh_port = config.ssh&.port || 2222
      def home_dir = "/home/#{username}"

      def install_xfce
        info "Installing XFCE4 desktop"
        shell.apt_install(
          "xfce4", "xfce4-goodies", "xfce4-terminal", "xorg", "dbus-x11",
          "arc-theme", "papirus-icon-theme",
        )
        ok "XFCE4 installed with Arc theme and Papirus icons"
      end

      def configure_xfwm
        conf_dir = "#{home_dir}/.config/xfce4/xfconf/xfce-perchannel-xml"
        FileUtils.mkdir_p(conf_dir)
        xml_path = "#{conf_dir}/xfwm4.xml"
        if File.exist?(xml_path)
          skip "xfwm4 config already exists"
          return
        end
        File.write(xml_path, XFWM4_XML)
        shell.sh!("chown -R #{username}:#{username} #{home_dir}/.config")
        ok "XFCE compositor disabled, Arc-Dark theme set"
      end

      def install_xrdp
        info "Installing XRDP"
        shell.apt_install("xrdp")

        if File.exist?("/etc/xrdp/cert.pem")
          skip "XRDP TLS certificate already exists"
        else
          shell.sh!(
            "openssl req -x509 -newkey rsa:2048 -nodes " \
            "-keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem " \
            "-days 3650 -subj '/CN=dev-boxer'"
          )
          ok "XRDP TLS certificate generated"
        end

        FileUtils.cp(template_path("xrdp.ini"),  "/etc/xrdp/xrdp.ini")
        FileUtils.cp(template_path("startwm.sh"), "/etc/xrdp/startwm.sh")
        File.chmod(0o755, "/etc/xrdp/startwm.sh")

        shell.sh("adduser xrdp ssl-cert")
        shell.systemctl(:enable, "xrdp")
        shell.systemctl(:restart, "xrdp")
        ok "XRDP configured and started"
      end
    end
  end
end
