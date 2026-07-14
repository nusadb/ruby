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
  module ConnectionAdapters
    class NusaDBAdapter < AbstractAdapter
      ADAPTER_NAME = "NusaDB"

      # ActiveRecord 7.2 rebuilt how an adapter gets its connection, and 8.0 removed the old way:
      #
      #   <= 7.1  ConnectionHandling#nusadb_connection opens the connection and hands it to
      #           .new(connection, logger, config); the adapter is simply born connected.
      #   >= 7.2  the adapter is resolved from a registry and built with .new(config). It starts
      #           with no connection at all: the base class calls the private #connect on first use
      #           and owns the result as @raw_connection, which every statement must reach through
      #           #with_raw_connection so the base can verify, materialize transactions and retry.
      #
      # Both eras are supported, so this constant -- not the ActiveRecord version number -- is what
      # the code below branches on. #with_raw_connection arrived in 7.1, one release before the
      # lazy-connection contract it belongs to, so a 7.1 adapter is connected eagerly and still
      # talks through it; that is harmless, and it keeps the branch to a single question.
      LAZY_CONNECTION = AbstractAdapter.private_method_defined?(:with_raw_connection) ||
                        AbstractAdapter.method_defined?(:with_raw_connection)

      # ActiveRecord 8.1 inserted +cast_type+ as Column's SECOND positional argument -- exactly where
      # +default+ used to sit. The old call still runs, it just hands the default over as the cast
      # type, and the column dies later with `undefined method 'mutable?' for nil`, nowhere near the
      # cause. The parameter list is asked rather than the version number because this is not the
      # 7-vs-8 line one would guess: 8.0 kept the old signature and only 8.1 changed it.
      COLUMN_TAKES_CAST_TYPE = Column.instance_method(:initialize).parameters.any? do |_kind, name|
        name == :cast_type
      end

      class << self
        # 7.2+ calls this from #connect. The <= 7.1 hook at the bottom of this file calls it too, so
        # a connection is opened the same way whichever era we are running under.
        def new_client(config)
          config = config.symbolize_keys
          NusaDB.connect(
            host: config[:host] || "127.0.0.1",
            port: (config[:port] || 5678).to_i,
            user: config[:username] || config[:user] || "nusa-root",
            database: config[:database] || "nusadb",
            password: config[:password]
          )
        end
      end

      # A connection this adapter has not opened yet is not active -- and saying otherwise is not a
      # white lie on 7.2+, where #active? is what tells the base class whether it still needs to
      # #connect. Claiming true while @raw_connection is nil sends it straight to a NoMethodError.
      def active?
        !current_raw_connection.nil?
      end

      def disconnect!
        super
        current_raw_connection&.close
        @raw_connection = nil if LAZY_CONNECTION
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

      # ActiveRecord 7.2 moved quoting onto the adapter *class* -- ActiveRecord::Base reaches for
      # `adapter_class.quote_column_name` before any connection exists (to quote a model's primary
      # key, say) -- and made the instance methods delegate to it. The class-level default raises
      # NotImplementedError, so an adapter that only defines the instance methods still looks fine
      # until something asks the class, and then dies far from the cause.
      class << self
        def quote_column_name(name)
          %("#{name.to_s.gsub('"', '""')}")
        end

        def quote_table_name(name)
          quote_column_name(name)
        end

        # Only ' is escaped, and deliberately: the server does not treat \ as an escape character
        # inside a string literal, so doubling backslashes (as the ActiveRecord default does) would
        # store them doubled.
        def quote_string(s)
          s.gsub("'", "''")
        end
      end

      # <= 7.1 has no class-level quoting to delegate to -- its Quoting module only ever calls the
      # instance methods, whose default raises. Delegating explicitly keeps one implementation
      # reachable from either era.
      def quote_column_name(name)
        self.class.quote_column_name(name)
      end

      def quote_table_name(name)
        self.class.quote_table_name(name)
      end

      def quote_string(s)
        self.class.quote_string(s)
      end

      # --- statement execution ---

      # Every keyword splat below absorbs arguments ActiveRecord grew later and passes to adapters
      # that never asked for them -- `allow_retry:` on #execute, `returning:` on #exec_insert,
      # `async:` on #internal_exec_query (all 7.2+). Without them the caller gets an ArgumentError.
      def execute(sql, name = nil, **_kwargs)
        log(sql, name) { nusa_query(sql) }
      end

      # #exec_query stopped being the way in. From 7.2 the internal read path (select_all -> select)
      # calls #internal_exec_query, whose base implementation raises NotImplementedError -- so an
      # adapter that overrides only the public #exec_query looks complete, loads fine, and then dies
      # on the first SELECT. This is the real entry point; #exec_query is kept for <= 7.1 (where the
      # base has no #internal_exec_query at all) and for anyone calling it directly.
      def internal_exec_query(sql, name = "SQL", binds = [], prepare: false, **_kwargs)
        result = log(sql, name) { nusa_query(sql) }
        ActiveRecord::Result.new(result.columns, result.rows)
      end

      def exec_query(sql, name = "SQL", binds = [], prepare: false, **_kwargs)
        internal_exec_query(sql, name, binds)
      end

      def exec_insert(sql, name = nil, binds = [], pk = nil, sequence_name = nil, **_kwargs)
        internal_exec_query(sql, name, binds)
      end

      def exec_delete(sql, name = nil, binds = [], **_kwargs)
        log(sql, name) { nusa_query(sql) }.affected
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
        nusa_query("SHOW TABLES").rows.map { |row| row[0] }
      end

      def data_source_exists?(name)
        tables.include?(name.to_s)
      end
      alias table_exists? data_source_exists?

      def data_sources
        tables
      end

      def columns(table_name, _name = nil)
        rows = nusa_query("SHOW COLUMNS FROM #{quote_table_name(table_name)}").rows
        rows.map do |row|
          col_name = row[0]
          sql_type = (row[1] || "text").to_s.downcase
          nullable = row[2].nil? || %w[t true yes 1].include?(row[2].to_s.downcase)
          cast_type = ActiveRecord::Type.lookup(map_type(sql_type))
          metadata = fetch_type_metadata(sql_type, cast_type)

          # The column has no default either way -- what moves is where +default+ sits in the
          # argument list. See COLUMN_TAKES_CAST_TYPE.
          if COLUMN_TAKES_CAST_TYPE
            Column.new(col_name, cast_type, nil, metadata, nullable)
          else
            Column.new(col_name, nil, metadata, nullable)
          end
        end
      end

      # The primary-key columns of +table_name+, in key order, so ActiveRecord can auto-detect a
      # model's primary key (single- or composite-column) without an explicit +self.primary_key+.
      # Resolved from +information_schema+ in two steps — the server does not support joining two
      # +information_schema+ tables in one query, so we look up the PRIMARY KEY constraint name and
      # then its columns separately.
      def primary_keys(table_name)
        name = quote(table_name.to_s)
        constraint = nusa_query(
          "SELECT constraint_name FROM information_schema.table_constraints " \
          "WHERE constraint_type = 'PRIMARY KEY' AND table_name = #{name}"
        ).rows.first
        return [] if constraint.nil?

        nusa_query(
          "SELECT column_name FROM information_schema.key_column_usage " \
          "WHERE table_name = #{name} AND constraint_name = #{quote(constraint[0])} " \
          "ORDER BY ordinal_position"
        ).rows.map { |row| row[0] }
      end

      private

      # Every statement funnels through here. On 7.1+ that means #with_raw_connection, which is not
      # a formality: it is what verifies the connection, materializes a lazy transaction before the
      # statement lands, and retries a query the base class judges retryable. Reaching for
      # @raw_connection directly would quietly bypass all three.
      def nusa_query(sql)
        if LAZY_CONNECTION
          with_raw_connection { |conn| conn.query(sql) }
        else
          @connection.query(sql)
        end
      end

      # The connection as it stands, WITHOUT opening one. #active? and #disconnect! both need to ask
      # "is there a connection?" without answering "...well, there is now".
      def current_raw_connection
        LAZY_CONNECTION ? @raw_connection : @connection
      end

      # The base class's own statement machinery, which the public methods above mostly bypass. It
      # is implemented anyway so that any path into it lands on the driver rather than on a
      # NotImplementedError: 7.2 drives statements through #raw_execute, and 8.0 replaced that with
      # #perform_query plus #cast_result / #affected_rows. Keyword splats, because the exact
      # signature moved between those releases.
      def raw_execute(sql, name = nil, *, **)
        log(sql, name) { nusa_query(sql) }
      end

      def perform_query(raw_connection, sql, *, **)
        raw_connection.query(sql)
      end

      def cast_result(raw_result)
        ActiveRecord::Result.new(raw_result.columns, raw_result.rows)
      end

      def affected_rows(raw_result)
        raw_result.affected
      end

      # 7.2+ only: the base class calls these to open (and re-open) the connection it owns.
      def connect
        @raw_connection = self.class.new_client(@config)
      end

      def reconnect
        current_raw_connection&.close
        @raw_connection = nil
        connect
      end

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

# How ActiveRecord finds this adapter when a config says `adapter: "nusadb"`.
#
# 7.2+ looks it up in a registry, and 8.0 deleted the old lookup outright: an unregistered adapter
# now raises AdapterNotFound ("Available adapters are: ...") before any connection is attempted, so
# registering is not a nicety -- without it the adapter is simply unreachable on Rails 8.
if ActiveRecord::ConnectionAdapters.respond_to?(:register)
  ActiveRecord::ConnectionAdapters.register(
    "nusadb",
    "ActiveRecord::ConnectionAdapters::NusaDBAdapter",
    "active_record/connection_adapters/nusadb_adapter"
  )
else
  # <= 7.1 instead calls ConnectionHandling#<adapter>_connection and expects an adapter that is
  # already connected -- hence the eager new_client here, where 7.2+ leaves it to #connect.
  module ActiveRecord
    module ConnectionHandling
      def nusadb_connection(config)
        config = config.symbolize_keys
        conn = ConnectionAdapters::NusaDBAdapter.new_client(config)
        ConnectionAdapters::NusaDBAdapter.new(conn, logger, config)
      end
    end
  end
end
