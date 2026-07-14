# frozen_string_literal: true

require_relative 'lib/nusadb'

Gem::Specification.new do |spec|
  spec.name = 'nusadb'
  spec.version = NusaDB::VERSION
  spec.authors = ['NusaDB Authors']
  spec.summary = 'Pure-Ruby client for NusaDB (Nusa Wire Protocol)'
  spec.description = 'A pure-Ruby driver that speaks the Nusa Wire Protocol directly over a socket.'
  spec.homepage = 'https://github.com/nusadb/nusadb'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 2.7'

  spec.files = Dir['lib/**/*.rb', 'README.md']
  spec.require_paths = ['lib']
  # Uses only the standard library (socket, openssl, securerandom, base64).
end
