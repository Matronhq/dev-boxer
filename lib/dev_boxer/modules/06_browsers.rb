module DevBoxer
  module Modules
    class Browsers < ModuleBase
      module_name  "browsers"
      module_order 6

      MOZILLA_PIN = <<~PIN
        Package: firefox*
        Pin: origin packages.mozilla.org
        Pin-Priority: 1001
      PIN

      def run
        section "Browsers"
        install_chrome
        install_firefox
        info "Installing Xvfb for headless browser automation"
        shell.apt_install("xvfb")
        ok "Browsers setup complete"
      end

      private

      def install_chrome
        if shell.command_exists?("google-chrome-stable")
          skip "Google Chrome already installed"
          return
        end
        info "Installing Google Chrome"
        shell.sh!(
          "curl -fsSL https://dl.google.com/linux/linux_signing_key.pub " \
          "| gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg"
        )
        arch = shell.sh!("dpkg --print-architecture").strip
        repo = "deb [arch=#{arch} signed-by=/usr/share/keyrings/google-chrome.gpg] " \
               "https://dl.google.com/linux/chrome/deb/ stable main\n"
        shell.write_file("/etc/apt/sources.list.d/google-chrome.list", repo)
        shell.apt_update
        shell.apt_install("google-chrome-stable")
        ok "Google Chrome installed"
      end

      def install_firefox
        if shell.command_exists?("firefox")
          skip "Firefox already installed"
          return
        end
        info "Installing Firefox (native deb)"

        shell.sh!("install -d -m 0755 /etc/apt/keyrings")
        shell.sh!(
          "curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg " \
          "| gpg --dearmor --yes -o /etc/apt/keyrings/packages.mozilla.org.gpg"
        )
        repo = "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.gpg] " \
               "https://packages.mozilla.org/apt mozilla main\n"
        shell.write_file("/etc/apt/sources.list.d/mozilla.list", repo)
        shell.write_file("/etc/apt/preferences.d/mozilla", MOZILLA_PIN)

        shell.apt_update
        shell.apt_install("firefox")
        ok "Firefox installed (native deb)"
      end
    end
  end
end
