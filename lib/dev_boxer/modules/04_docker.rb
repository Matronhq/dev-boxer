module DevBoxer
  module Modules
    class Docker < ModuleBase
      module_name  "docker"
      module_order 4

      def run
        section "Docker"
        install_docker
        add_user_to_docker_group
        shell.systemctl(:enable, "docker")
        shell.systemctl(:start, "docker")
        ok "Docker enabled and running"
      end

      private

      def username = config.user.name

      def install_docker
        if shell.command_exists?("docker")
          skip "Docker already installed"
          return
        end
        info "Installing Docker CE"

        shell.sh!("install -m 0755 -d /etc/apt/keyrings")
        shell.sh!("curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc")
        shell.sh!("chmod a+r /etc/apt/keyrings/docker.asc")

        arch     = shell.sh!("dpkg --print-architecture").strip
        codename = shell.sh!(". /etc/os-release && echo $VERSION_CODENAME").strip

        repo_line = "deb [arch=#{arch} signed-by=/etc/apt/keyrings/docker.asc] " \
                    "https://download.docker.com/linux/ubuntu #{codename} stable\n"
        shell.write_file("/etc/apt/sources.list.d/docker.list", repo_line)

        shell.apt_update
        shell.apt_install(
          "docker-ce", "docker-ce-cli", "containerd.io",
          "docker-buildx-plugin", "docker-compose-plugin",
        )
        ok "Docker CE installed"
      end

      def add_user_to_docker_group
        if shell.sh("groups #{username} | grep -q docker")
          skip "User #{username} already in docker group"
        else
          shell.sh!("usermod -aG docker #{username}")
          ok "User #{username} added to docker group"
        end
      end
    end
  end
end
