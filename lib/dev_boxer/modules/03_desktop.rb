module DevBoxer
  module Modules
    class Desktop < ModuleBase
      module_name  "desktop"
      module_order 3

      SHORTCUTS = [
        ["VS Code",  "code",                  "visual-studio-code"],
        ["Firefox",  "firefox",               "firefox"],
        ["Chrome",   "google-chrome-stable",  "google-chrome"],
        ["Terminal", "xfce4-terminal",        "utilities-terminal"],
      ].freeze

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
        install_vscode
        install_github_desktop
        write_desktop_shortcuts
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

      def install_vscode
        if shell.command_exists?("code")
          skip "VS Code already installed"
          return
        end
        info "Installing VS Code"
        shell.sh!(
          "curl -fsSL https://packages.microsoft.com/keys/microsoft.asc " \
          "| gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg"
        )
        arch = shell.sh!("dpkg --print-architecture").strip
        repo = "deb [arch=#{arch} signed-by=/usr/share/keyrings/microsoft.gpg] " \
               "https://packages.microsoft.com/repos/code stable main\n"
        shell.write_file("/etc/apt/sources.list.d/vscode.list", repo)
        shell.apt_update
        shell.apt_install("code")
        ok "VS Code installed"
      end

      def install_github_desktop
        if shell.command_exists?("github-desktop")
          skip "GitHub Desktop already installed"
          return
        end
        info "Installing GitHub Desktop"
        shell.sh!(
          "curl -fsSL https://apt.packages.shiftkey.dev/gpg.key " \
          "| gpg --dearmor --yes -o /usr/share/keyrings/shiftkey-packages.gpg"
        )
        arch = shell.sh!("dpkg --print-architecture").strip
        repo = "deb [arch=#{arch} signed-by=/usr/share/keyrings/shiftkey-packages.gpg] " \
               "https://apt.packages.shiftkey.dev/ubuntu/ any main\n"
        shell.write_file("/etc/apt/sources.list.d/shiftkey-packages.list", repo)
        shell.apt_update
        shell.apt_install("github-desktop")
        ok "GitHub Desktop installed"
      rescue Shell::Error => e
        warn "GitHub Desktop install skipped (#{first_error_line(e)})"
      end

      def first_error_line(error)
        error.message.lines.map(&:strip).find { |line| !line.empty? } || error.class.name
      end

      def write_desktop_shortcuts
        desktop_dir = "#{home_dir}/Desktop"
        FileUtils.mkdir_p(desktop_dir)
        SHORTCUTS.each do |name, exec, icon|
          path = "#{desktop_dir}/#{name}.desktop"
          File.write(path, <<~ENTRY)
            [Desktop Entry]
            Type=Application
            Name=#{name}
            Exec=#{exec}
            Icon=#{icon}
            Terminal=false
          ENTRY
          File.chmod(0o755, path)
        end
        shell.sh!("chown -R #{username}:#{username} #{desktop_dir}")
        ok "Desktop shortcuts created"
      end
    end
  end
end
