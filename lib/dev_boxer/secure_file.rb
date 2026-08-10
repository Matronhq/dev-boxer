require "fileutils"
require "securerandom"

module DevBoxer
  # Writes a file that must never be readable by anyone but its owner — not
  # even for the moment between the write and File.chmod.
  #
  # File.write is unsafe here in both directions:
  #
  #   - creating a NEW file applies the process umask, 0644 on a default box,
  #     so the secret is world-readable until File.chmod runs;
  #   - writing over an EXISTING file keeps that file's current mode, so a
  #     target left at 0644 by an earlier interrupted run stays 0644 while the
  #     new secret is written into it. Tightening the umask does not help,
  #     because umask only applies at creation.
  #
  # So the content goes to a fresh same-directory temporary file opened with
  # the target mode, which is then renamed over the target. rename(2) within a
  # directory is atomic: a reader sees either the old file or the new one,
  # never a partial write and never a briefly-permissive one. A failure part
  # way through leaves the target untouched rather than truncated.
  #
  # rename replaces the inode, so the result is owned by the running process
  # (root, during provisioning). Every caller that needs another owner chowns
  # immediately afterwards; the rest are root-owned by design.
  module SecureFile
    def self.write(path, content, mode)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      tmp = File.join(dir, ".#{File.basename(path)}.#{SecureRandom.hex(8)}.tmp")

      begin
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, mode) { |f| f.write(content) }
        # File.open masks the mode through the umask; chmod sets it exactly.
        # Safe to do here because tmp is not yet at its final name.
        File.chmod(mode, tmp)
        File.rename(tmp, path)
      rescue StandardError
        FileUtils.rm_f(tmp)
        raise
      end
    end
  end
end
