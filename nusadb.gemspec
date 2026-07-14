# frozen_string_literal: true

require_relative 'lib/nusadb'

Gem::Specification.new do |spec|
  spec.name = 'nusadb'
  spec.version = NusaDB::VERSION
  spec.authors = ['NusaDB Authors']
  spec.summary = 'Pure-Ruby client for NusaDB (Nusa Wire Protocol)'
  spec.description = 'A pure-Ruby driver that speaks the Nusa Wire Protocol directly over a socket.'
  spec.homepage = 'https://github.com/nusadb/ruby'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 2.7'

  # Rendered as the sidebar links on rubygems.org/gems/nusadb.
  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => spec.homepage,
    'bug_tracker_uri' => "#{spec.homepage}/issues"
  }

  spec.files = Dir['lib/**/*.rb', 'README.md']
  spec.require_paths = ['lib']
  # No runtime dependencies: the driver uses only the standard library (socket, openssl,
  # securerandom, bigdecimal, date, time, json). ActiveRecord is deliberately not one -- the
  # adapter under lib/active_record is loaded only by an app that already has ActiveRecord, and
  # declaring it here would force the ORM on every user of the bare driver.
end
