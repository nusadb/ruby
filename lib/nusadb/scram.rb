# frozen_string_literal: true

require 'openssl'
require 'securerandom'
require 'base64'

module NusaDB
  # Client-side SCRAM-SHA-256 (RFC 5802 / RFC 7677), docs/wire-protocol.md §7.2.
  # Uses Ruby's bundled OpenSSL / SecureRandom — no gems.
  class Scram
    GS2_HEADER = 'n,,'
    CHANNEL_BINDING = Base64.strict_encode64(GS2_HEADER)

    attr_reader :client_first_bare, :full_client_first

    def initialize(user)
      nonce = Base64.strict_encode64(SecureRandom.random_bytes(18))
      @client_first_bare = "n=#{user},r=#{nonce}"
      @full_client_first = GS2_HEADER + @client_first_bare
      @expected_signature = ''
    end

    def client_final(password, server_first)
      combined_nonce = nil
      salt = nil
      iterations = 0
      server_first.split(',').each do |field|
        key, _, value = field.partition('=')
        next if value.nil? || key.empty?

        case key
        when 'r' then combined_nonce = value
        when 's' then salt = Base64.strict_decode64(value)
        when 'i' then iterations = value.to_i
        end
      end
      if combined_nonce.nil? || salt.nil? || iterations <= 0
        raise NusaError.new('nusadb: malformed server-first message', '08P01')
      end

      salted = OpenSSL::PKCS5.pbkdf2_hmac(password, salt, iterations, 32, OpenSSL::Digest::SHA256.new)
      client_key = hmac(salted, 'Client Key')
      stored_key = OpenSSL::Digest::SHA256.digest(client_key)

      without_proof = "c=#{CHANNEL_BINDING},r=#{combined_nonce}"
      auth_message = "#{@client_first_bare},#{server_first},#{without_proof}"
      client_sig = hmac(stored_key, auth_message)
      proof = xor(client_key, client_sig)
      final = "#{without_proof},p=#{Base64.strict_encode64(proof)}"

      server_key = hmac(salted, 'Server Key')
      @expected_signature = Base64.strict_encode64(hmac(server_key, auth_message))
      final
    end

    def verify_server_final(server_final)
      got = ''
      server_final.split(',').each do |field|
        got = field[2..] if field.start_with?('v=')
      end
      OpenSSL.fixed_length_secure_compare(got, @expected_signature)
    rescue ArgumentError
      false # lengths differ
    end

    private

    def hmac(key, msg)
      OpenSSL::HMAC.digest('SHA256', key, msg)
    end

    def xor(a, b)
      a.bytes.zip(b.bytes).map { |x, y| x ^ y }.pack('C*')
    end
  end
end
