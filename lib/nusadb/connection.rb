# frozen_string_literal: true

require 'socket'
require 'bigdecimal'
require 'date'
require 'time'
require 'json'

module NusaDB
  # A driver or server error; +sql_state+ is the 5-character SQLSTATE (docs/wire-protocol.md §14).
  class NusaError < StandardError
    attr_reader :sql_state

    def initialize(message, sql_state = 'HY000')
      super(message)
      @sql_state = sql_state
    end
  end

  # The result of a statement: column names, rows (each an array of String/nil), and the command tag.
  class Result
    include Enumerable

    attr_reader :columns, :column_types, :rows, :command

    def initialize(columns, rows, command, column_types = nil)
      @columns = columns
      @rows = rows
      @command = command
      # Per-column type name (protocol 1.1, R42-B.03), parallel to +columns+; each entry is a
      # canonical name such as 'INT'/'TEXT' or nil if the server did not report it.
      @column_types = column_types || Array.new(columns.size)
    end

    # Iterate rows as hashes keyed by column name.
    def each
      return enum_for(:each) unless block_given?

      @rows.each do |row|
        yield @columns.each_with_index.to_h { |name, i| [name, row[i]] }
      end
    end

    def to_a
      each.to_a
    end

    # The affected-row count parsed from the trailing number of the command tag.
    def affected
      return 0 if @command.nil?

      last = @command.split(' ').last
      last =~ /\A\d+\z/ ? last.to_i : 0
    end
  end

  # An asynchronous LISTEN/NOTIFY message delivered by the server: the notifying backend's +pid+, the
  # +channel+, and its (possibly empty) +payload+.
  Notification = Struct.new(:pid, :channel, :payload)

  # One authenticated connection to a NusaDB server.
  class Connection
    attr_reader :backend_key

    def initialize(host: '127.0.0.1', port: 5678, user: 'nusa-root', database: 'nusadb', password: 'nusa-root')
      @user = user
      @counter = 0
      @backend_key = nil
      # Async LISTEN/NOTIFY messages received while reading other responses; drained by #notifications.
      @notifications = []
      begin
        @socket = TCPSocket.new(host, port)
        # Disable Nagle's algorithm: this is a request/response protocol, so
        # coalescing small frames only adds delayed-ACK latency per round-trip.
        @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      rescue SystemCallError => e
        raise NusaError.new("nusadb: connect failed: #{e.message}", '08001')
      end
      handshake(user, database, password)
    end

    # Run one SQL string, optionally with positional parameters ($1, $2, …).
    def query(sql, params = [])
      raw = if params && !params.empty?
              run_extended(sql, params)
            else
              run_simple(sql)
            end
      shape(raw)
    end

    # Prepare a statement for repeated execution; returns an object with #execute(params).
    def prepare(sql)
      name = fresh_name('stmt')
      send_frame(Protocol.parse(name, sql))
      send_frame(Protocol.sync)
      collect # surfaces a parse error
      Statement.new(self, name)
    end

    # Run a statement returning the affected-row count.
    def execute(sql, params = [])
      query(sql, params).affected
    end

    # Run one statement once per parameter set, reusing a single prepared statement — the bulk
    # insert/update path. Returns an Array of per-set affected-row counts. One parse, then one
    # execute per set (the wire protocol has no batch pipeline, so this is N round-trips, not one);
    # the first failing set raises.
    def execute_many(sql, param_sets)
      stmt = prepare(sql)
      (param_sets || []).map { |params| stmt.execute(params).affected }
    end

    # Bulk-load via COPY ... FROM STDIN (§12.1). +source+ is an IO (responds to #read) or a String
    # already in the server's text format (tab-delimited, \N for NULL). Returns the loaded row count.
    # A refused COPY (bad SQL, an RLS-protected table) raises; the connection stays usable.
    def copy_in(sql, source)
      send_frame(Protocol.query(sql))
      await_copy_start(Protocol::B_COPY_IN)
      if source.respond_to?(:read)
        loop do
          # A read error on the source aborts the load with CopyFail (mirrors the other drivers),
          # then drains to ReadyForQuery so the connection stays usable.
          begin
            chunk = source.read(65_536)
          rescue StandardError => e
            send_frame(Protocol.copy_fail('nusadb: client read error during COPY'))
            drain_to_ready
            raise NusaError.new("nusadb: COPY source read failed: #{e.message}", '57014')
          end
          break if chunk.nil?

          send_frame(Protocol.copy_data(chunk.b)) unless chunk.empty?
        end
      else
        bytes = source.to_s.dup.force_encoding(Encoding::BINARY)
        (0...bytes.bytesize).step(65_536) { |off| send_frame(Protocol.copy_data(bytes.byteslice(off, 65_536))) }
      end
      send_frame(Protocol.copy_done)
      finish_copy
    end

    # Bulk-export via COPY ... TO STDOUT (§12.2). Writes each data chunk to +sink+ (responds to
    # #write) in the server's text format; returns the exported row count.
    def copy_out(sql, sink)
      send_frame(Protocol.query(sql))
      await_copy_start(Protocol::B_COPY_OUT)
      loop do
        type, reader = read_message
        case type
        when Protocol::B_COPY_DATA then sink.write(reader.rest)
        when Protocol::B_COPY_DONE then break
        when Protocol::B_ERROR
          err = server_error(reader)
          drain_to_ready
          raise err
        end
      end
      finish_copy
    end

    def close
      send_frame(Protocol.terminate)
    rescue IOError, SystemCallError
      # best effort
    ensure
      @socket.close unless @socket.closed?
    end

    # Subscribe to asynchronous notifications on +channel+ (+LISTEN channel+). Collect them with
    # #notifications or #poll.
    def listen(channel)
      run_simple("LISTEN #{quote_identifier(channel)}")
      nil
    end

    # Stop listening on +channel+ (+UNLISTEN channel+); +nil+ unlistens all (+UNLISTEN *+).
    def unlisten(channel = nil)
      target = channel.nil? ? '*' : quote_identifier(channel)
      run_simple("UNLISTEN #{target}")
      nil
    end

    # Send a notification on +channel+ with an optional +payload+ (+NOTIFY channel[, 'payload']+).
    def notify(channel, payload = nil)
      sql = "NOTIFY #{quote_identifier(channel)}"
      sql += ", #{quote_literal(payload)}" unless payload.nil?
      run_simple(sql)
      nil
    end

    # Return and clear the notifications already received (buffered while reading other responses).
    # Does not touch the socket -- use #poll to wait for new ones.
    def notifications
      pending = @notifications
      @notifications = []
      pending
    end

    # Wait up to +timeout+ seconds for the next notification (a buffered one is returned immediately;
    # +nil+ on timeout). +timeout+ of +nil+ blocks until one arrives. Only meaningful after #listen.
    def poll(timeout = 0)
      return @notifications.shift unless @notifications.empty?

      return nil if IO.select([@socket], nil, nil, timeout).nil?

      type, reader = read_message
      case type
      when Protocol::B_NOTIFICATION then decode_notification(reader)
      when Protocol::B_ERROR then raise server_error(reader)
      else
        raise NusaError.new('nusadb: unexpected message while polling for notifications', '08006')
      end
    end

    # @api private
    def run_prepared(name, params)
      portal = fresh_name('portal')
      send_frame(Protocol.bind(portal, name, encode_params(params)))
      send_frame(Protocol.describe_portal(portal))
      send_frame(Protocol.execute(portal, 0))
      send_frame(Protocol.sync)
      shape(collect)
    end

    private

    def decode_notification(reader)
      Notification.new(reader.u32, reader.str, reader.str)
    end

    # Quote an identifier (a LISTEN/NOTIFY channel) so an arbitrary name is emitted safely; the
    # server folds a quoted identifier to its literal value.
    def quote_identifier(name)
      %("#{name.to_s.gsub('"', '""')}")
    end

    # Quote a string as a SQL literal ('...', doubling '), for a NOTIFY payload.
    def quote_literal(text)
      "'#{text.to_s.gsub("'", "''")}'"
    end

    def send_frame(frame)
      @socket.write(frame)
    end

    def read_exact(n)
      data = @socket.read(n)
      raise NusaError.new('nusadb: server closed the connection', '08006') if data.nil? || data.bytesize < n

      data
    end

    def read_message
      header = read_exact(Protocol::HEADER_LEN)
      type = header.getbyte(0)
      total = header.byteslice(1, 4).unpack1('N')
      if total < Protocol::HEADER_LEN || total > Protocol::MAX_FRAME_LEN
        raise NusaError.new("nusadb: invalid frame length #{total}", '08P01')
      end

      payload = total > Protocol::HEADER_LEN ? read_exact(total - Protocol::HEADER_LEN) : ''.b
      [type, Reader.new(payload)]
    end

    def handshake(user, database, password)
      send_frame(Protocol.startup(user, database))
      loop do
        type, reader = read_message
        case type
        when Protocol::B_READY then return
        when Protocol::B_ERROR then raise server_error(reader)
        when Protocol::B_AUTH
          scram(reader, user, password) if reader.u32 == Protocol::AUTH_SASL
        when Protocol::B_BACKEND_KEY
          @backend_key = { pid: reader.u32, secret: reader.u32 }
        end
      end
    end

    def scram(offer, user, password)
      count = offer.u16
      supported = false
      count.times { supported = true if offer.str == Protocol::SCRAM_MECHANISM }
      raise NusaError.new('nusadb: server offered no supported SASL mechanism', '28000') unless supported
      raise NusaError.new('nusadb: server requires a password but none was given', '28000') if password.nil?

      scram = Scram.new(user)
      send_frame(Protocol.sasl_initial(Protocol::SCRAM_MECHANISM, scram.full_client_first.b))

      type, reader = read_message
      raise server_error(reader) if type == Protocol::B_ERROR
      unless type == Protocol::B_AUTH && reader.u32 == Protocol::AUTH_SASL_CONTINUE
        raise NusaError.new('nusadb: expected a SASL continue message', '08P01')
      end
      server_first = reader.rest.force_encoding(Encoding::UTF_8)

      send_frame(Protocol.sasl_response(scram.client_final(password, server_first).b))

      type, reader = read_message
      raise server_error(reader) if type == Protocol::B_ERROR
      unless type == Protocol::B_AUTH && reader.u32 == Protocol::AUTH_SASL_FINAL
        raise NusaError.new('nusadb: expected a SASL final message', '08P01')
      end
      return if scram.verify_server_final(reader.rest.force_encoding(Encoding::UTF_8))

      raise NusaError.new('nusadb: server signature did not verify', '28000')
    end

    def collect
      columns = []
      column_types = []
      rows = []
      tag = nil
      error = nil
      loop do
        type, reader = read_message
        case type
        when Protocol::B_ROW_DESCRIPTION
          columns = Array.new(reader.u16) { reader.str }
          column_types = Array.new(columns.size)
        when Protocol::B_ROW_DESCRIPTION_TYPED
          # Protocol 1.1: each column is a name plus a 1-byte type tag (§9.2).
          count = reader.u16
          columns = []
          column_types = []
          count.times do
            columns << reader.str
            column_types << Protocol.type_name(reader.u8)
          end
        when Protocol::B_DATA_ROW
          rows << reader.fields
        when Protocol::B_COMMAND_COMPLETE
          tag = reader.str
        when Protocol::B_NOTIFICATION
          # A pending LISTEN/NOTIFY message can lead the next query's response; buffer it.
          @notifications << decode_notification(reader)
        when Protocol::B_ERROR
          error = server_error(reader)
        when Protocol::B_READY
          raise error if error

          return { columns: columns, column_types: column_types, rows: rows, tag: tag }
        end
      end
    end

    def run_simple(sql)
      send_frame(Protocol.query(sql))
      collect
    end

    # Read until the expected CopyInResponse/CopyOutResponse; a refused COPY arrives as Error then
    # ReadyForQuery and is raised, the connection left ready.
    def await_copy_start(expected)
      error = nil
      loop do
        type, reader = read_message
        case type
        when expected then return
        when Protocol::B_ERROR then error = server_error(reader)
        when Protocol::B_READY
          raise(error || NusaError.new('nusadb: COPY did not start', '08P01'))
        end
      end
    end

    # Drain to ReadyForQuery, returning the row count from the "COPY <n>" command tag.
    def finish_copy
      tag = nil
      error = nil
      loop do
        type, reader = read_message
        case type
        when Protocol::B_COMMAND_COMPLETE then tag = reader.str
        when Protocol::B_ERROR then error = server_error(reader)
        when Protocol::B_READY
          raise error if error

          return copy_count(tag)
        end
      end
    end

    # Best-effort resync: read and discard frames until ReadyForQuery.
    def drain_to_ready
      loop { break if read_message[0] == Protocol::B_READY }
    end

    def copy_count(tag)
      return 0 if tag.nil?

      last = tag.split(' ').last
      last =~ /\A\d+\z/ ? last.to_i : 0
    end

    def run_extended(sql, params)
      send_frame(Protocol.parse('', sql))
      send_frame(Protocol.bind('', '', encode_params(params)))
      send_frame(Protocol.describe_portal(''))
      send_frame(Protocol.execute('', 0))
      send_frame(Protocol.sync)
      collect
    end

    def encode_params(params)
      params.map do |value|
        if value.nil?
          nil
        elsif value == true
          'true'.b
        elsif value == false
          'false'.b
        elsif value.is_a?(String) && value.encoding == Encoding::BINARY
          # A binary-encoded String is BYTEA: send the \x<hex> text the server coerces into BYTEA.
          "\\x#{value.unpack1('H*')}".b
        else
          value.to_s.dup.force_encoding(Encoding::BINARY)
        end
      end
    end

    def shape(raw)
      types = raw[:column_types] || []
      rows = raw[:rows].map do |fields|
        fields.each_index.map { |i| decode_cell(fields[i], types[i]) }
      end
      Result.new(raw[:columns], rows, raw[:tag], raw[:column_types])
    end

    # Decode a text-format cell into the natural Ruby type for its protocol 1.1 type tag: BOOL ->
    # boolean, INT -> Integer, FLOAT -> Float, NUMERIC -> BigDecimal, DATE -> Date, TIMESTAMP ->
    # Time, JSON -> parsed value, ARRAY -> Array, BYTES -> binary String. TEXT/UUID/TIME/INTERVAL
    # stay UTF-8 strings. A value that does not parse as its tag falls back to the raw text.
    def decode_cell(cell, type)
      return nil if cell.nil?
      return decode_bytea(cell) if type == 'BYTES'

      text = cell.force_encoding(Encoding::UTF_8)
      case type
      when 'BOOL' then %w[true t 1].include?(text)
      when 'INT' then (Integer(text, 10) rescue text)
      when 'FLOAT' then (Float(text) rescue text)
      when 'NUMERIC' then (BigDecimal(text) rescue text)
      when 'DATE' then (Date.parse(text) rescue text)
      when 'TIMESTAMP', 'TIMESTAMPTZ' then (Time.parse(text) rescue text)
      when 'JSON' then (JSON.parse(text) rescue text)
      when 'ARRAY' then (parse_array(text) rescue text)
      else text
      end
    end

    def decode_bytea(cell)
      text = cell.force_encoding(Encoding::UTF_8)
      hex = text.start_with?('\x') ? text[2..] : text
      [hex].pack('H*')
    end

    # Parse a SQL array literal (`{a,b,c}`, possibly nested, quoted, or with NULL) into a Ruby
    # Array. Elements stay strings (the wire array tag carries no per-element type); a quoted element
    # is unescaped and an unquoted NULL becomes nil.
    def parse_array(text)
      value, pos = parse_array_at(text, 0)
      raise 'trailing array data' unless pos == text.length

      value
    end

    def parse_array_at(text, pos)
      raise 'not an array' unless text[pos] == '{'

      pos += 1
      items = []
      return [items, pos + 1] if text[pos] == '}'

      loop do
        case text[pos]
        when '{' then val, pos = parse_array_at(text, pos)
        when '"' then val, pos = parse_quoted_at(text, pos)
        else val, pos = parse_unquoted_at(text, pos)
        end
        items << val
        case text[pos]
        when ',' then pos += 1
        when '}' then return [items, pos + 1]
        else raise 'malformed array'
        end
      end
    end

    def parse_quoted_at(text, pos)
      pos += 1 # opening quote
      out = +''
      while text[pos] != '"'
        raise 'unterminated array element' if pos >= text.length

        pos += 1 if text[pos] == '\\'
        out << text[pos]
        pos += 1
      end
      [out, pos + 1]
    end

    def parse_unquoted_at(text, pos)
      start = pos
      pos += 1 while pos < text.length && text[pos] != ',' && text[pos] != '}'
      token = text[start...pos]
      [token == 'NULL' ? nil : token, pos]
    end

    def fresh_name(prefix)
      @counter += 1
      "nusa_#{prefix}_#{@counter}"
    end

    def server_error(reader)
      code = reader.str
      message = reader.str
      NusaError.new("nusadb: #{message}", code)
    end
  end

  # A prepared statement handle.
  class Statement
    attr_reader :name

    def initialize(connection, name)
      @connection = connection
      @name = name
    end

    def execute(params = [])
      @connection.run_prepared(@name, params)
    end
  end
end
