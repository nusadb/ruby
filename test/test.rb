# frozen_string_literal: true

# Integration tests for the NusaDB Ruby driver against a real server.
# Run: ruby drivers/ruby/test/test.rb   (after `cargo build -p nusadb-server`).

require 'socket'
require 'tmpdir'
require_relative '../lib/nusadb'

REPO_ROOT = File.expand_path('../../..', __dir__)

def server_binary
  bases = []
  env = ENV['CARGO_TARGET_DIR']
  bases << env if env && !env.empty?
  bases << File.join(REPO_ROOT, 'target')
  names = Gem.win_platform? ? ['nusadb-server.exe'] : ['nusadb-server']
  bases.each do |base|
    %w[debug release].each do |profile|
      names.each do |name|
        path = File.join(base, profile, name)
        return path if File.exist?(path)
      end
    end
  end
  nil
end

def free_port
  server = TCPServer.new('127.0.0.1', 0)
  port = server.addr[1]
  server.close
  port
end

def wait_ready(port)
  deadline = Time.now + 15
  while Time.now < deadline
    begin
      TCPSocket.new('127.0.0.1', port).close
      return
    rescue SystemCallError
      sleep 0.1
    end
  end
  raise "server on port #{port} did not become ready"
end

def start_server(*extra)
  bin = server_binary
  if bin.nil?
    warn 'SKIP: nusadb-server binary not found; run `cargo build -p nusadb-server`'
    exit 0
  end
  port = free_port
  dir = Dir.mktmpdir('nusadb-ruby-')
  pid = spawn(
    { 'RUST_LOG' => 'error' },
    bin, '--listen', "127.0.0.1:#{port}", '--data-dir', dir,
    *extra,
    out: File::NULL, err: File::NULL
  )
  wait_ready(port)
  { pid: pid, port: port, dir: dir }
end

def stop_server(server)
  Process.kill('KILL', server[:pid])
  Process.wait(server[:pid])
rescue Errno::ESRCH, Errno::ECHILD
  # already gone
ensure
  FileUtils.remove_entry(server[:dir]) if File.directory?(server[:dir])
end

require 'fileutils'

$passed = 0
$failed = 0

def check(name)
  yield
  $passed += 1
  puts "ok   - #{name}"
rescue StandardError => e
  $failed += 1
  puts "FAIL - #{name}\n      #{e.message}"
end

def expect(condition, what)
  raise "expectation failed: #{what}" unless condition
end

trust = start_server
begin
  port = trust[:port]

  check('simple query round trip') do
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    conn.query('CREATE TABLE rb_simple (id INT NOT NULL, name TEXT)')
    expect(conn.execute("INSERT INTO rb_simple VALUES (5, 'alice')") == 1, 'insert count == 1')
    result = conn.query('SELECT id, name FROM rb_simple')
    expect(result.columns == %w[id name], 'columns')
    # Protocol 1.1 typed metadata (R42-B.03): per-column type names.
    expect(result.column_types == %w[INT TEXT], 'column types')
    expect(result.rows == [[5, 'alice']], 'one row') # INT -> Integer, TEXT -> String
    expect(result.to_a == [{ 'id' => 5, 'name' => 'alice' }], 'hash rows')
    conn.close
  end

  check('copy bulk load and export') do
    require 'stringio'
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    conn.query('CREATE TABLE rb_copy (id INT NOT NULL, name TEXT, PRIMARY KEY (id))')

    # COPY FROM STDIN: tab-delimited rows, \N for NULL.
    loaded = conn.copy_in('COPY rb_copy FROM STDIN', StringIO.new("1\talice\n2\t\\N\n3\tcarol\n"))
    expect(loaded == 3, 'copy_in loaded 3 rows')

    result = conn.query('SELECT id, name FROM rb_copy ORDER BY id')
    expect(result.rows == [[1, 'alice'], [2, nil], [3, 'carol']], 'rows with NULL')

    # COPY TO STDOUT: bytes come back in the same text format.
    sink = StringIO.new
    exported = conn.copy_out('COPY rb_copy TO STDOUT', sink)
    expect(exported == 3, 'copy_out exported 3 rows')
    expect(sink.string.split("\n") == ["1\talice", "2\t\\N", "3\tcarol"], 'exported text')

    # A refused COPY raises; the connection stays usable.
    raised = false
    begin
      conn.copy_in('COPY no_such_table FROM STDIN', StringIO.new(''))
    rescue NusaDB::NusaError
      raised = true
    end
    expect(raised, 'COPY into a missing table raises')
    expect(conn.query('SELECT count(*) FROM rb_copy').rows.length == 1, 'connection usable')
    conn.close
  end

  check('bytea round trip') do
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    conn.query('CREATE TABLE bt (id INT NOT NULL, data BYTEA, PRIMARY KEY (id))')
    payload = "\xde\xad\xbe\xef\x00\x7f".b
    conn.execute('INSERT INTO bt VALUES ($1, $2)', [1, payload])
    conn.execute('INSERT INTO bt VALUES ($1, $2)', [2, ''.b])
    conn.execute('INSERT INTO bt VALUES ($1, $2)', [3, nil])
    result = conn.query('SELECT id, data FROM bt ORDER BY id')
    expect(result.rows[0][1] == payload, 'bytea round-trips losslessly')
    expect(result.rows[0][1].encoding == Encoding::BINARY, 'bytea decodes to a binary String')
    expect(result.rows[1][1] == ''.b, 'empty bytea')
    expect(result.rows[2][1].nil?, 'null bytea')
    conn.close
  end

  check('typed value decoding') do
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    conn.query('CREATE TABLE rb_typed (b BOOL, i INT, f FLOAT, n NUMERIC(10,2), ' \
               'd DATE, ts TIMESTAMP, arr INT[])')
    conn.query("INSERT INTO rb_typed VALUES (true, 42, 1.5, 12.34, DATE '2024-01-15', " \
               "TIMESTAMP '2024-01-15 10:30:00', ARRAY[1, 2, 3])")
    row = conn.query('SELECT b, i, f, n, d, ts, arr FROM rb_typed').rows[0]
    b, i, f, n, d, ts, arr = row
    expect(b == true, 'BOOL -> true')
    expect(i == 42 && i.is_a?(Integer), 'INT -> Integer 42')
    expect(f == 1.5 && f.is_a?(Float), 'FLOAT -> Float 1.5')
    expect(n == BigDecimal('12.34'), 'NUMERIC -> BigDecimal')
    expect(d.is_a?(Date), 'DATE -> Date')
    expect(ts.is_a?(Time), 'TIMESTAMP -> Time')
    expect(arr == %w[1 2 3], 'ARRAY -> Array of strings')
    conn.close
  end

  check('NULL values decode to nil') do
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    conn.query('CREATE TABLE rb_typed_null (b BOOL, i INT, d DATE, arr INT[])')
    conn.query('INSERT INTO rb_typed_null VALUES (NULL, NULL, NULL, NULL)')
    expect(conn.query('SELECT b, i, d, arr FROM rb_typed_null').rows == [[nil, nil, nil, nil]], 'all nil')
    conn.close
  end

  check('parameterised query with NULL') do
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    conn.query('CREATE TABLE rb_params (id INT NOT NULL, name TEXT)')
    conn.execute('INSERT INTO rb_params VALUES ($1, $2)', [1, 'alice'])
    conn.execute('INSERT INTO rb_params VALUES ($1, $2)', [2, nil])
    result = conn.query('SELECT id, name FROM rb_params WHERE id = $1', [2])
    expect(result.rows == [[2, nil]], 'row is [2, nil]')
    conn.close
  end

  check('prepared statement reused') do
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    conn.query('CREATE TABLE rb_prep (id INT NOT NULL)')
    stmt = conn.prepare('INSERT INTO rb_prep VALUES ($1)')
    (1..3).each { |i| stmt.execute([i]) }
    expect(conn.query('SELECT id FROM rb_prep').rows.length == 3, 'three rows')
    conn.close
  end

  check('execute_many bulk insert') do
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    conn.query('CREATE TABLE rb_batch (id INT NOT NULL, name TEXT)')
    counts = conn.execute_many('INSERT INTO rb_batch VALUES ($1, $2)', [[1, 'a'], [2, 'b'], [3, 'c']])
    expect(counts == [1, 1, 1], 'each set affected 1 row')
    expect(conn.query('SELECT count(*) FROM rb_batch').rows[0][0] == 3, 'three rows persisted')
    expect(conn.execute_many('INSERT INTO rb_batch VALUES ($1, $2)', []) == [], 'empty batch is a no-op')
    conn.close
  end

  check('query surface') do
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    conn.query('CREATE TABLE surf_a (id INT NOT NULL, grp TEXT, v INT)')
    conn.execute("INSERT INTO surf_a VALUES (1, 'a', 10)")
    conn.execute("INSERT INTO surf_a VALUES (2, 'a', 30)")
    conn.execute("INSERT INTO surf_a VALUES (3, 'b', 20)")
    conn.execute("INSERT INTO surf_a VALUES (4, 'b', 20)")
    conn.execute("INSERT INTO surf_a VALUES (5, 'a', 10)")
    conn.query('CREATE TABLE surf_b (id INT NOT NULL, a_id INT, tag TEXT)')
    conn.execute("INSERT INTO surf_b VALUES (10, 1, 'p')")
    conn.execute("INSERT INTO surf_b VALUES (11, 1, 'q')")
    conn.execute("INSERT INTO surf_b VALUES (12, 2, 'r')")

    surface = [
      ['A ORDER BY',    'SELECT id FROM surf_a ORDER BY v DESC, id', 5],
      ['B DISTINCT',    'SELECT DISTINCT v FROM surf_a ORDER BY v', 3],
      ['C DISTINCT ON', 'SELECT DISTINCT ON (grp) grp, v FROM surf_a ORDER BY grp, v', 2],
      ['D LIMIT',       'SELECT id FROM surf_a ORDER BY id LIMIT 2', 2],
      ['E OFFSET',      'SELECT id FROM surf_a ORDER BY id LIMIT 2 OFFSET 3', 2],
      ['F GROUP/HAVING', 'SELECT grp, count(*) FROM surf_a GROUP BY grp HAVING count(*) > 1 ORDER BY grp', 2],
      ['G window',      'SELECT id, row_number() OVER (PARTITION BY grp ORDER BY v) FROM surf_a ORDER BY id', 5],
      ['H CTE',         'WITH g AS (SELECT grp, count(*) c FROM surf_a GROUP BY grp) SELECT count(*) FROM g', 1],
      ['I subquery IN', 'SELECT id FROM surf_a WHERE v IN (SELECT max(v) FROM surf_a) ORDER BY id', 1],
      ['J UNION',       'SELECT id FROM surf_a WHERE id = 1 UNION SELECT id FROM surf_a WHERE id = 2', 2],
      ['K INNER JOIN',  'SELECT surf_a.grp, surf_b.tag FROM surf_a JOIN surf_b ON surf_a.id = surf_b.a_id ORDER BY surf_b.id', 3],
      ['L LEFT JOIN',   'SELECT surf_a.grp, surf_b.tag FROM surf_a LEFT JOIN surf_b ON surf_a.id = surf_b.a_id ORDER BY surf_a.id, surf_b.id', 6],
      ['M RIGHT JOIN',  'SELECT surf_a.grp, surf_b.tag FROM surf_a RIGHT JOIN surf_b ON surf_a.id = surf_b.a_id ORDER BY surf_b.id', 3],
      ['N FULL JOIN',   'SELECT surf_a.grp, surf_b.tag FROM surf_a FULL JOIN surf_b ON surf_a.id = surf_b.a_id ORDER BY surf_a.id, surf_b.id', 6],
      ['O CROSS JOIN',  'SELECT surf_a.id, surf_b.id FROM surf_a CROSS JOIN surf_b', 15],
      ['P LATERAL',     'SELECT surf_a.id, l.tag FROM surf_a JOIN LATERAL (SELECT tag FROM surf_b WHERE surf_b.a_id = surf_a.id LIMIT 1) l ON true ORDER BY surf_a.id', 2]
    ]
    surface.each do |label, sql, want|
      got = conn.query(sql).rows.length
      expect(got == want, "#{label} returns #{want} rows (got #{got})")
    end
    conn.close
  end

  check('server error surfaces and connection survives') do
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    threw = false
    begin
      conn.query('SELECT * FROM ghost')
    rescue NusaDB::NusaError => e
      threw = true
      expect(e.sql_state.length == 5, '5-char SQLSTATE')
    end
    expect(threw, 'missing table raises')
    expect(conn.query('SELECT 1').rows.length == 1, 'connection usable after error')
    conn.close
  end

  check('LISTEN/NOTIFY self-delivery') do
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    conn.listen('rb_chan')
    # Self-delivery: NOTIFY on a channel this connection listens to comes back to it.
    conn.notify('rb_chan', 'hello')
    note = conn.poll(5)
    expect(!note.nil?, 'a notification was delivered')
    expect(note.channel == 'rb_chan', 'channel is rb_chan')
    expect(note.payload == 'hello', 'payload is hello')
    # NOTIFY without a payload delivers an empty string.
    conn.notify('rb_chan')
    note2 = conn.poll(5)
    expect(!note2.nil? && note2.payload == '', 'empty payload')
    # After UNLISTEN, a further NOTIFY is not delivered (poll times out -> nil).
    conn.unlisten('rb_chan')
    conn.notify('rb_chan', 'ignored')
    expect(conn.poll(0.3).nil?, 'no notification after unlisten')
    conn.close
  end

  check('savepoint rollback and release') do
    conn = NusaDB.connect(port: port, user: 'u', database: 'nusadb')
    conn.query('CREATE TABLE rb_sp (id INT NOT NULL)')
    conn.query('BEGIN')
    conn.query('INSERT INTO rb_sp VALUES (1)')
    conn.query('SAVEPOINT sp1')
    conn.query('INSERT INTO rb_sp VALUES (2)')
    conn.query('ROLLBACK TO SAVEPOINT sp1') # undoes (2), keeps (1)
    conn.query('INSERT INTO rb_sp VALUES (3)')
    conn.query('SAVEPOINT sp2')
    conn.query('INSERT INTO rb_sp VALUES (4)')
    conn.query('RELEASE SAVEPOINT sp2') # keeps (4)
    conn.query('COMMIT')
    rows = conn.query('SELECT id FROM rb_sp ORDER BY id').rows
    expect(rows == [[1], [3], [4]], 'savepoint kept 1,3,4 (2 rolled back)')
    conn.close
  end
ensure
  stop_server(trust)
end

auth = start_server('--auth-user', 'alice:secret')
begin
  port = auth[:port]

  check('scram correct password') do
    conn = NusaDB.connect(port: port, user: 'alice', database: 'nusadb', password: 'secret')
    expect(conn.query('SELECT 1').rows.length == 1, 'authenticated query')
    conn.close
  end

  check('scram wrong password') do
    threw = false
    begin
      NusaDB.connect(port: port, user: 'alice', database: 'nusadb', password: 'wrong')
    rescue NusaDB::NusaError
      threw = true
    end
    expect(threw, 'wrong password rejected')
  end
ensure
  stop_server(auth)
end

puts "\n#{$passed} passed, #{$failed} failed"
exit($failed.zero? ? 0 : 1)
