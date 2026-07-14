# frozen_string_literal: true

# ActiveRecord adapter for NusaDB, built on the pure-Ruby `nusadb` driver.
#
# Use it by setting the adapter to "nusadb" in database.yml or establish_connection:
#
#     ActiveRecord::Base.establish_connection(
#       adapter: "nusadb", host: "127.0.0.1", port: 5678, username: "nusa-root", database: "nusadb")
#
# Values are inlined (prepared_statements is off), so the server sees plain SQL with constant
# LIMIT/OFFSET and no bind markers.

require "active_record"
require "active_record/connection_adapters/abstract_adapter"
require "nusadb"

module ActiveRecord
  module ConnectionHandling
    def nusadb_connection(config)
      config = config.symbolize_keys
      conn = NusaDB.connect(
        host: config[:host] || "127.0.0.1",
        port: (config[:port] || 5678).to_i,
        user: config[:username] || config[:user] || "nusa-root",
        database: config[:database] || "nusadb",
        password: config[:password]
      )
      ConnectionAdapters::NusaDBAdapter.new(conn, logger, config)
    end
  end

  module ConnectionAdapters
    class NusaDBAdapter < AbstractAdapter
      ADAPTER_NAME = "NusaDB"

      def initialize(connection, logger, config)
        super(connection, logger, config)
      end

      def active?
        true
      end

      def reconnect!
        super
      end

      def disconnect!
        super
        @connection.close
      rescue StandardError
        nil
      end

      def prepared_statements
        false
      end

      def supports_migrations?
        true
      end

      # NusaDB supports savepoints (SAVEPOINT / ROLLBACK TO SAVEPOINT / RELEASE SAVEPOINT), so
      # ActiveRecord can map nested `transaction(requires_new: true)` blocks onto them. The base
      # adapter's create_savepoint / exec_rollback_to_savepoint / release_savepoint emit exactly the
      # statements the server accepts, so enabling the capability is all that is needed.
      def supports_savepoints?
        true
      end

      def native_database_types
        {
          primary_key: "INT",
          string: { name: "TEXT" },
          text: { name: "TEXT" },
          integer: { name: "INT" },
          bigint: { name: "INT" },
          float: { name: "FLOAT" },
          decimal: { name: "NUMERIC" },
          boolean: { name: "BOOL" },
          date: { name: "DATE" },
          datetime: { name: "TIMESTAMP" },
          time: { name: "TIME" }
        }
      end

      # --- quoting (values are inlined since prepared_statements is off) ---

      def quote_column_name(name)
        %("#{name.to_s.gsub('"', '""')}")
      end

      def quote_table_name(name)
        %("#{name.to_s.gsub('"', '""')}")
      end

      def quote_string(s)
        s.gsub("'", "''")
      end

      # --- statement execution ---

      def execute(sql, name = nil)
        log(sql, name) { @connection.query(sql) }
      end

      def exec_query(sql, name = "SQL", binds = [], prepare: false)
        result = log(sql, name) { @connection.query(sql) }
        ActiveRecord::Result.new(result.columns, result.rows)
      end

      def exec_insert(sql, name = nil, binds = [], pk = nil, sequence_name = nil)
        exec_query(sql, name, binds)
      end

      def exec_delete(sql, name = nil, binds = [])
        log(sql, name) { @connection.query(sql) }.affected
      end
      alias exec_update exec_delete

      def begin_db_transaction
        execute("BEGIN")
      end

      def commit_db_transaction
        execute("COMMIT")
      end

      def exec_rollback_db_transaction
        execute("ROLLBACK")
      end

      # --- schema introspection ---

      def tables
        @connection.query("SHOW TABLES").rows.map { |row| row[0] }
      end

      def data_source_exists?(name)
        tables.include?(name.to_s)
      end
      alias table_exists? data_source_exists?

      def data_sources
        tables
      end

      def columns(table_name, _name = nil)
        rows = @connection.query("SHOW COLUMNS FROM #{quote_table_name(table_name)}").rows
        rows.map do |row|
          col_name = row[0]
          sql_type = (row[1] || "text").to_s.downcase
          nullable = row[2].nil? || %w[t true yes 1].include?(row[2].to_s.downcase)
          cast_type = ActiveRecord::Type.lookup(map_type(sql_type))
          ActiveRecord::ConnectionAdapters::Column.new(
            col_name, nil, fetch_type_metadata(sql_type, cast_type), nullable
          )
        end
      end

      # The primary-key columns of +table_name+, in key order, so ActiveRecord can auto-detect a
      # model's primary key (single- or composite-column) without an explicit +self.primary_key+.
      # Resolved from +information_schema+ in two steps — the server does not support joining two
      # +information_schema+ tables in one query, so we look up the PRIMARY KEY constraint name and
      # then its columns separately.
      def primary_keys(table_name)
        name = quote(table_name.to_s)
        constraint = @connection.query(
          "SELECT constraint_name FROM information_schema.table_constraints " \
          "WHERE constraint_type = 'PRIMARY KEY' AND table_name = #{name}"
        ).rows.first
        return [] if constraint.nil?

        @connection.query(
          "SELECT column_name FROM information_schema.key_column_usage " \
          "WHERE table_name = #{name} AND constraint_name = #{quote(constraint[0])} " \
          "ORDER BY ordinal_position"
        ).rows.map { |row| row[0] }
      end

      private

      def fetch_type_metadata(sql_type, cast_type)
        ActiveRecord::ConnectionAdapters::SqlTypeMetadata.new(
          sql_type: sql_type,
          type: cast_type.type,
          limit: nil,
          precision: nil,
          scale: nil
        )
      end

      def map_type(sql_type)
        case sql_type
        when /int/ then :integer
        when /bool/ then :boolean
        when /float|double|real/ then :float
        when /numeric|decimal/ then :decimal
        when /timestamp|datetime/ then :datetime
        when /date/ then :date
        when /time/ then :time
        else :string
        end
      end
    end
  end
end
