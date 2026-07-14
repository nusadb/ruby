# frozen_string_literal: true

require_relative 'nusadb/protocol'
require_relative 'nusadb/scram'
require_relative 'nusadb/connection'

# NusaDB — pure-Ruby client for the Nusa Wire Protocol (PROTOCOL_VERSION 1.1).
#
# Example:
#
#   conn = NusaDB.connect(host: '127.0.0.1', port: 5678, user: 'nusa-root', database: 'nusadb')
#   conn.query('CREATE TABLE t (id INT NOT NULL, name TEXT)')
#   conn.execute('INSERT INTO t VALUES ($1, $2)', [1, 'alice'])
#   conn.query('SELECT id, name FROM t WHERE id = $1', [1]).each { |row| p row }
#   conn.close
module NusaDB
  VERSION = '0.1.0'

  # Open a connection (see Connection#initialize for options).
  def self.connect(**options)
    Connection.new(**options)
  end
end
