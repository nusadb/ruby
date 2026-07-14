# frozen_string_literal: true

# ActiveRecord integration tests for the NusaDB adapter, against a real server.
# Run: ruby drivers/ruby/test/test_activerecord.rb   (after `cargo build -p nusadb-server`).
# Skipped automatically if ActiveRecord is not installed.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "socket"
require "tmpdir"
require "fileutils"

begin
  require "active_record"
  require "active_record/connection_adapters/nusadb_adapter"
  HAVE_AR = true
rescue LoadError
  HAVE_AR = false
end

REPO_ROOT = File.expand_path("../../..", __dir__)

def server_binary
  bases = [ENV["CARGO_TARGET_DIR"], File.join(REPO_ROOT, "target")].compact
  names = Gem.win_platform? ? ["nusadb-server.exe"] : ["nusadb-server"]
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
  s = TCPServer.new("127.0.0.1", 0)
  port = s.addr[1]
  s.close
  port
end

def wait_ready(port)
  deadline = Time.now + 15
  while Time.now < deadline
    begin
      TCPSocket.new("127.0.0.1", port).close
      return
    rescue SystemCallError
      sleep 0.1
    end
  end
  raise "server not ready"
end

def with_server
  bin = server_binary
  if bin.nil?
    warn "SKIP: nusadb-server binary not found"
    return
  end
  port = free_port
  dir = Dir.mktmpdir("nusadb-ar-")
  pid = spawn({ "RUST_LOG" => "error" }, bin, "--listen", "127.0.0.1:#{port}", "--data-dir", dir,
              out: File::NULL, err: File::NULL)
  wait_ready(port)
  yield port
ensure
  if pid
    Process.kill("KILL", pid)
    Process.wait(pid)
  end
  FileUtils.remove_entry(dir) if dir && File.directory?(dir)
end

passed = 0
failed = 0

def check(name)
  yield
  print "ok   - #{name}\n"
  true
rescue StandardError => e
  warn "FAIL - #{name}\n      #{e.class}: #{e.message}"
  false
end

unless HAVE_AR
  warn "SKIP: ActiveRecord not installed"
  exit 0
end

with_server do |port|
  ActiveRecord::Base.establish_connection(
    adapter: "nusadb", host: "127.0.0.1", port: port, username: "u", database: "nusadb"
  )

  # An explicit-key model (the server has no auto-increment).
  ar_class = Class.new(ActiveRecord::Base) do
    self.table_name = "ar_products"
    self.primary_key = "id"
  end
  Object.const_set(:ArProduct, ar_class) unless Object.const_defined?(:ArProduct)

  passed += 1 if check("migrate creates the table") do
    ActiveRecord::Schema.define do
      create_table :ar_products, id: false do |t|
        t.integer :id, null: false
        t.string :name
        t.integer :price
      end
    end
    raise "table missing" unless ActiveRecord::Base.connection.table_exists?("ar_products")
  end

  passed += 1 if check("create and read via the ORM") do
    ArProduct.create!(id: 1, name: "alice", price: 10)
    ArProduct.create!(id: 2, name: "bob", price: 20)
    raise "wrong count" unless ArProduct.count == 2
    raise "wrong name" unless ArProduct.find(1).name == "alice"
    names = ArProduct.order(:id).pluck(:name)
    raise "wrong order #{names.inspect}" unless names == %w[alice bob]
  end

  passed += 1 if check("update and delete via the ORM") do
    p = ArProduct.find(1)
    p.update!(price: 15)
    raise "update failed" unless ArProduct.find(1).price == 15
    ArProduct.find(2).destroy
    raise "delete failed" unless ArProduct.count == 1
  end

  passed += 1 if check("transaction rolls back") do
    begin
      ArProduct.transaction do
        ArProduct.create!(id: 99, name: "temp")
        raise ActiveRecord::Rollback
      end
    end
    raise "rollback failed" if ArProduct.exists?(99)
  end

  passed += 1 if check("primary_keys introspection (single + composite)") do
    conn = ActiveRecord::Base.connection
    # A model over a table with a real PRIMARY KEY must auto-detect it (no explicit primary_key).
    conn.execute("CREATE TABLE ar_pk_one (id INT NOT NULL, name TEXT, PRIMARY KEY (id))")
    auto = Class.new(ActiveRecord::Base) { self.table_name = "ar_pk_one" }
    raise "single PK #{auto.primary_key.inspect}" unless auto.primary_key == "id"

    conn.execute("CREATE TABLE ar_pk_two (a INT NOT NULL, b INT NOT NULL, note TEXT, PRIMARY KEY (a, b))")
    pks = conn.primary_keys("ar_pk_two")
    raise "composite PK #{pks.inspect}" unless pks == %w[a b]
  end

  passed += 1 if check("limit / offset paginate, where + aggregates") do
    [[10, 100], [11, 200], [12, 300], [13, 400]].each do |id, price|
      ArProduct.create!(id: id, name: "p#{id}", price: price)
    end
    scope = ArProduct.where("id >= 10")
    page = scope.order(:id).limit(2).offset(1).pluck(:id)
    raise "pagination #{page.inspect}" unless page == [11, 12]
    raise "count" unless scope.where("price >= 200").count == 3
    raise "sum" unless scope.sum(:price) == 1000
    raise "min" unless scope.minimum(:price) == 100
    raise "max" unless scope.maximum(:price) == 400
    raise "avg" unless scope.average(:price).to_f == 250.0
  end

  passed += 1 if check("joins across tables") do
    ActiveRecord::Schema.define do
      create_table :ar_categories, id: false do |t|
        t.integer :id, null: false
        t.string :label
      end
      create_table :ar_items, id: false do |t|
        t.integer :id, null: false
        t.integer :category_id
        t.string :name
      end
    end
    cat = Class.new(ActiveRecord::Base) { self.table_name = "ar_categories"; self.primary_key = "id" }
    item = Class.new(ActiveRecord::Base) { self.table_name = "ar_items"; self.primary_key = "id" }
    Object.const_set(:ArCategory, cat) unless Object.const_defined?(:ArCategory)
    Object.const_set(:ArItem, item) unless Object.const_defined?(:ArItem)
    ArCategory.create!(id: 1, label: "fruit")
    ArCategory.create!(id: 2, label: "veg")
    ArItem.create!(id: 1, category_id: 1, name: "apple")
    ArItem.create!(id: 2, category_id: 2, name: "kale")
    ArItem.create!(id: 3, category_id: 99, name: "orphan")
    rows = ArItem.joins("JOIN ar_categories ON ar_categories.id = ar_items.category_id")
                 .order("ar_items.id")
                 .pluck("ar_items.name", "ar_categories.label")
    raise "join #{rows.inspect}" unless rows == [%w[apple fruit], %w[kale veg]]
  end

  failed = 7 - passed
end

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
