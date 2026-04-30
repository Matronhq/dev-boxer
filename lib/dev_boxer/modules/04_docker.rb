require "json"

module DevBoxer
  module Modules
    class Docker < ModuleBase
      module_name  "docker"
      module_order 4

      def run
        section "Docker"
        install_docker
        add_user_to_docker_group
        relocate_data_root if data_root
        install_prune_timer
        shell.systemctl(:enable, "docker")
        shell.systemctl(:start, "docker")
        ok "Docker enabled and running"
      end

      private

      def username = config.user.name
      def data_root = config.docker&.data_root

      # If the operator sets `data_root: /secure/docker` we can sensibly
      # auto-derive `/secure/containerd`. If they set anything else (e.g.
      # `/mnt/storage/docker-stuff`), the auto-derivation would silently
      # produce a string that doesn't end with /containerd — and worse,
      # `String#sub` returns the input unchanged on no-match, so
      # containerd_root would silently equal data_root and clobber it.
      # Require an explicit `containerd_root` in that case.
      def containerd_root
        return config.docker.containerd_root if config.docker&.containerd_root
        return nil unless data_root
        if data_root.end_with?("/docker")
          data_root.sub(%r{/docker\z}, "/containerd")
        else
          raise "config.docker.data_root (#{data_root}) doesn't end with '/docker'; " \
                "set config.docker.containerd_root explicitly"
        end
      end

      # Coerce to string: YAML parses bare numbers as Integer (`interval: 2`)
      # and Integer#sub doesn't exist. Defensive .to_s on both lets users write
      # either `interval: 2h` (a String) or `interval: 2` (an Integer that
      # becomes "2" → still no unit, but at least we don't crash).
      def prune_interval = (config.docker&.prune&.interval || "2h").to_s
      def prune_until    = (config.docker&.prune&.keep_until || "4h").to_s

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

      # Optional: relocate docker + containerd storage onto a separate volume
      # (e.g. a large data disk, or an encrypted /secure mount). Set
      # config.docker.data_root to opt in.
      def relocate_data_root
        docker_mount = mount_point_for(data_root)
        unless docker_mount
          warn "Skipping data-root relocation: no mount point in /proc/mounts is a parent of #{data_root}"
          return
        end

        # containerd_root may live on a different volume than data_root
        # (operator can pick storage independently). Resolve mount points
        # separately so each service's RequiresMountsFor= drop-in points
        # at the right disk.
        containerd_mount = containerd_root ? mount_point_for(containerd_root) : nil
        if containerd_root && !containerd_mount
          warn "containerd_root #{containerd_root} not under any mount; skipping"
          return
        end

        FileUtils.mkdir_p(data_root, mode: 0o711)
        FileUtils.mkdir_p(containerd_root, mode: 0o711) if containerd_root

        write_docker_daemon_json
        write_containerd_config if containerd_root
        write_wait_for_mount_dropin("docker", docker_mount)
        write_wait_for_mount_dropin("containerd", containerd_mount) if containerd_mount

        info "Relocating docker (#{data_root}) and containerd (#{containerd_root})"
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:restart, "containerd")
        shell.systemctl(:restart, "docker")
        ok "Docker storage relocated"
      end

      # Walk /proc/mounts and return the longest mount point that is a
      # parent of `path` (so e.g. `/mnt/data/docker` correctly resolves
      # to `/mnt/data` even though the bash version split on / and
      # returned `/mnt`).
      def mount_point_for(path)
        File.read("/proc/mounts").lines
          .map { |l| l.split[1] }
          .compact
          .select { |m| path == m || path.start_with?(m + "/") }
          .max_by(&:length)
      rescue Errno::ENOENT
        nil
      end

      def write_docker_daemon_json
        existing = File.exist?("/etc/docker/daemon.json") ?
          JSON.parse(File.read("/etc/docker/daemon.json")) : {}
        existing["data-root"] = data_root
        FileUtils.mkdir_p("/etc/docker")
        File.write("/etc/docker/daemon.json", JSON.pretty_generate(existing) + "\n")
      end

      # Update only the top-level `root = ` line in containerd's config.toml,
      # preserving any other settings the distro or operator put there
      # (sandbox_image, registries, plugin configs, etc.). The previous
      # implementation wrote a 2-line file that wiped all of those.
      def write_containerd_config
        path = "/etc/containerd/config.toml"
        FileUtils.mkdir_p("/etc/containerd")
        existing = File.exist?(path) ? File.read(path) : nil

        if existing.nil? || existing.strip.empty?
          File.write(path, "version = 2\nroot = #{containerd_root.inspect}\n")
          return
        end

        updated =
          if existing =~ /^root\s*=/
            existing.sub(/^root\s*=.*$/, "root = #{containerd_root.inspect}")
          elsif existing =~ /^version\s*=.*$/
            existing.sub(/^(version\s*=.*$)/, "\\1\nroot = #{containerd_root.inspect}")
          else
            "root = #{containerd_root.inspect}\n" + existing
          end

        File.write(path, updated)
      end

      def write_wait_for_mount_dropin(svc, mount_point)
        dir = "/etc/systemd/system/#{svc}.service.d"
        FileUtils.mkdir_p(dir)
        File.write("#{dir}/wait-for-mount.conf", <<~UNIT)
          [Unit]
          RequiresMountsFor=#{mount_point}
        UNIT
      end

      # Aggressive prune cadence keeps the OS disk healthy when running CI
      # runners, multi-project builds, or other image-churn workloads.
      def install_prune_timer
        write_prune_script
        write_prune_unit
        write_prune_timer
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:enable, "docker-prune.timer")
        shell.systemctl(:start, "docker-prune.timer")
        ok "docker-prune.timer enabled (every #{prune_interval}, until=#{prune_until})"
      end

      def write_prune_script
        File.write("/usr/local/bin/docker-prune.sh", <<~SH)
          #!/bin/bash
          set -e
          LOG=/var/log/docker-prune.log
          ts() { date '+%Y-%m-%d %H:%M:%S'; }
          log() { echo "[$(ts)] $1" | tee -a "$LOG"; }

          log "Starting Docker cleanup"
          docker container prune -f >> "$LOG" 2>&1
          docker image prune -a -f --filter "until=#{prune_until}" >> "$LOG" 2>&1
          docker volume prune -f >> "$LOG" 2>&1
          docker network prune -f >> "$LOG" 2>&1
          docker builder prune -f --filter "until=#{prune_until}" >> "$LOG" 2>&1

          if command -v ctr &>/dev/null; then
            ctr -n moby images prune --all >> "$LOG" 2>&1 || true
          fi
          docker system df >> "$LOG" 2>&1
          log "Docker cleanup completed"
        SH
        File.chmod(0o755, "/usr/local/bin/docker-prune.sh")
      end

      def write_prune_unit
        File.write("/etc/systemd/system/docker-prune.service", <<~UNIT)
          [Unit]
          Description=Docker system prune

          [Service]
          Type=oneshot
          ExecStart=/usr/local/bin/docker-prune.sh
        UNIT
      end

      def write_prune_timer
        File.write("/etc/systemd/system/docker-prune.timer", <<~TIMER)
          [Unit]
          Description=Docker system prune timer

          [Timer]
          OnCalendar=*-*-* 00/#{prune_interval.to_s.sub(/h\z/, '')}:00:00
          RandomizedDelaySec=600
          Persistent=true

          [Install]
          WantedBy=timers.target
        TIMER
      end
    end
  end
end
