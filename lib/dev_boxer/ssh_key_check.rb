require "base64"

module DevBoxer
  # Checks a pasted SSH public key before setup relies on it. Setup turns on
  # key-only SSH and disables root login, so a mangled key locks the operator
  # out of the server; refuse it at entry instead.
  module SshKeyCheck
    KEY_TYPES = %w[
      ssh-ed25519 ssh-rsa ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521
      sk-ssh-ed25519@openssh.com sk-ecdsa-sha2-nistp256@openssh.com
    ].freeze

    # nil when the value is one usable public key line, otherwise why not.
    def self.problem(value)
      key = value.to_s.strip
      return "nothing was entered" if key.empty?
      if key.include?("PRIVATE KEY")
        return "that is a private key; paste the public key (the .pub file) and keep the private key secret"
      end

      type, blob, = key.split(/\s+/, 3)
      unless KEY_TYPES.include?(type)
        return "it should start with one of: #{KEY_TYPES.first(3).join(", ")} (from a .pub file)"
      end
      # Every key blob starts "AAAA", so two "<type> AAAA" runs are two keys.
      if key.scan(/(?:#{KEY_TYPES.map { |t| Regexp.escape(t) }.join("|")})\s*AAAA/).length > 1
        return "it looks like more than one key, or the same key pasted twice; paste one key on one line"
      end
      return "the key data after #{type} is missing" if blob.to_s.empty?
      return "the key data is damaged (it should be base64); copy the whole line again" unless blob.match?(%r{\A[A-Za-z0-9+/]+={0,2}\z})

      embedded = embedded_type(blob)
      return "the key data is damaged or cut short; copy the whole line again" unless embedded == type

      nil
    end

    # An OpenSSH public key blob is a run of length-prefixed fields, the first
    # being the key type. Returns that type only if the fields use up the
    # blob exactly, so a key cut short (or with extra bytes) is caught.
    def self.embedded_type(blob)
      raw = Base64.strict_decode64(blob)
      fields = []
      offset = 0
      while offset < raw.bytesize
        return nil if raw.bytesize - offset < 4
        length = raw.byteslice(offset, 4).unpack1("N")
        offset += 4
        return nil if length > raw.bytesize - offset
        fields << raw.byteslice(offset, length)
        offset += length
      end
      fields.length >= 2 ? fields.first : nil
    rescue ArgumentError
      nil
    end
  end
end
