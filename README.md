# nusadb — Ruby driver for NusaDB

A pure-Ruby client (standard library only) that speaks the
[Nusa Wire Protocol](../../docs/wire-protocol.md) (`PROTOCOL_VERSION 1.1`) directly
over a socket. SCRAM-SHA-256 uses Ruby's bundled OpenSSL. Requires Ruby 2.7+.
`Result#column_types` reports each column's NusaDB type name (protocol 1.1).

## Install

```bash
gem install nusadb
```

Or point `$LOAD_PATH` at `drivers/ruby/lib` and `require 'nusadb'`.

## Usage

```ruby
require 'nusadb'

conn = NusaDB.connect(host: '127.0.0.1', port: 5678, user: 'nusa-root', database: 'nusadb')

conn.query('CREATE TABLE t (id INT NOT NULL, name TEXT)')
conn.execute('INSERT INTO t VALUES ($1, $2)', [1, 'alice'])

result = conn.query('SELECT id, name FROM t WHERE id = $1', [1])
result.each { |row| puts "#{row['id']} #{row['name']}" }   # hash per row
p result.rows                                              # [[1, "alice"]] (INT -> Integer)

conn.close
```

### Value types

Each cell decodes to the natural Ruby type for its protocol 1.1 type tag: `BOOL` → `true`/`false`,
`INT` → `Integer`, `FLOAT` → `Float`, `NUMERIC` → `BigDecimal`, `DATE` → `Date`, `TIMESTAMP`
(and `TIMESTAMPTZ`) → `Time`, `JSON` → the parsed value, `ARRAY` → `Array` (elements stay strings —
the wire array tag carries no element type), `BYTEA` → a binary `String`. `TEXT`, `UUID`, `TIME`,
and `INTERVAL` stay UTF-8 strings. A value that does not parse as its tag falls back to the raw
string, so an unexpected wire form never raises.

### Parameters

Placeholders are positional **`$1`, `$2`, …**; pass values as the second argument.
`nil` is SQL `NULL`. Result cells are strings (`nil` for SQL NULL).

### Prepared statements

```ruby
stmt = conn.prepare('INSERT INTO t VALUES ($1, $2)')
stmt.execute([1, 'a'])
stmt.execute([2, 'b'])
```

### Batch (bulk insert/update)

`conn.execute_many(sql, param_sets)` runs one statement once per parameter set, reusing a single
prepared statement, and returns an array of per-set affected-row counts. The wire protocol has no
batch pipeline, so this is N round-trips, not one.

```ruby
counts = conn.execute_many('INSERT INTO t VALUES ($1, $2)', [[1, 'a'], [2, 'b'], [3, 'c']])
```

### Bulk load / export (`COPY`)

For high-throughput load/export, `copy_in` / `copy_out` drive the `COPY` sub-protocol — one
round-trip for the whole dataset. Move bytes in the server's text format (tab-delimited fields, `\N`
for SQL `NULL`, one row per line); you write the `COPY` statement with any `WITH (...)` options.

```ruby
require 'stringio'

# Bulk load from an IO (responds to #read) or a String.
loaded = conn.copy_in('COPY t (id, name) FROM STDIN', StringIO.new("1\talice\n2\t\\N\n"))

# Bulk export into an IO (responds to #write).
sink = StringIO.new
exported = conn.copy_out('COPY t TO STDOUT', sink)
```

A `COPY` the server refuses (bad SQL, an RLS-protected table) raises; the connection stays usable.

### Authentication

For a server started with `--auth-user USER:PASSWORD`, pass `password:`; the driver
runs SCRAM-SHA-256 and verifies the server signature (mutual auth,
`OpenSSL.fixed_length_secure_compare`).

## ActiveRecord

An ActiveRecord adapter ships in
`lib/active_record/connection_adapters/nusadb_adapter.rb`:

```ruby
require "active_record/connection_adapters/nusadb_adapter"

ActiveRecord::Base.establish_connection(
  adapter: "nusadb", host: "127.0.0.1", port: 5678, username: "nusa-root", database: "nusadb")
```

It supports migrations (`create_table`, reflection via `SHOW TABLES`/`SHOW COLUMNS`),
CRUD, transactions, and the usual query surface — `where`, `limit`/`offset`, `order`,
`joins`, and aggregates (`count`/`sum`/`minimum`/`maximum`/`average`). Primary keys are
introspected from `information_schema` (`primary_keys`), so a model over a table with a
real `PRIMARY KEY` auto-detects its key (single- or composite-column). Values are inlined
(`prepared_statements` off), so the server sees plain SQL with constant `LIMIT`/`OFFSET`.
The server has no auto-increment, so assign ids explicitly (or declare a real PK).

## Transactions

The driver itself runs each statement autocommit; explicit transactions work via the
adapter (or by sending `BEGIN`/`COMMIT`/`ROLLBACK` as queries), backed by the server's
transaction support. The ActiveRecord adapter reports `supports_savepoints?`, so nested
`transaction(requires_new: true)` blocks map onto `SAVEPOINT` / `ROLLBACK TO SAVEPOINT` /
`RELEASE SAVEPOINT`. With the low-level driver, send those statements as queries.

## Notifications (LISTEN/NOTIFY)

`listen(channel)` subscribes the connection; a `notify(channel, payload)` from any connection on the
same database is then delivered asynchronously. `poll(timeout)` waits for the next one (seconds;
`nil` blocks), or `notifications` drains those buffered during other queries:

```ruby
conn.listen('orders')
# ... elsewhere: other.notify('orders', '42')
note = conn.poll(5)   # => NusaDB::Notification(pid, channel, payload), or nil on timeout
puts "#{note.channel} #{note.payload}"
conn.unlisten('orders')
```

## Test

```bash
cargo build -p nusadb-server
ruby drivers/ruby/test/test.rb
```

The test boots a real `nusadb-server` (ephemeral port, honouring `CARGO_TARGET_DIR`)
and covers simple/parameterised/prepared queries, errors, and SCRAM auth.

## License

Apache-2.0.
