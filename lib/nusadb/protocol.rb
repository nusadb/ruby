# frozen_string_literal: true

module NusaDB
  # Low-level Nusa Wire Protocol codec (docs/wire-protocol.md, PROTOCOL_VERSION 1.1).
  #
  # A frame is [type:u8][len:u32][payload]; len is the total including the 5-byte header.
  # Big-endian throughout; strings are [len:u32][utf8 bytes], not null-terminated.
  module Protocol
    MAGIC = 0x4E55_5341 # "NUSA"
    MAJOR = 1
    # Request minor 1 to receive the typed RowDescription (per-column type tags). A 1.0 server
    # ignores it and answers with the classic untyped form, which the driver still handles.
    MINOR = 1
    HEADER_LEN = 5
    MAX_FRAME_LEN = 256 * 1024 * 1024
    SCRAM_MECHANISM = 'SCRAM-SHA-256'

    # Frontend type bytes.
    T_STARTUP = 'S'.ord
    T_QUERY = 'Q'.ord
    T_PARSE = 'P'.ord
    T_BIND = 'B'.ord
    T_DESCRIBE = 'D'.ord
    T_EXECUTE = 'E'.ord
    T_SYNC = 'Y'.ord
    T_SASL_INITIAL = 'p'.ord
    T_SASL_RESPONSE = 'r'.ord
    T_TERMINATE = 'X'.ord
    T_COPY_DATA = 'd'.ord # COPY ... FROM STDIN data chunk (§12.1)
    T_COPY_DONE = 'c'.ord # end of the client's COPY data stream
    T_COPY_FAIL = 'f'.ord # abort the in-progress COPY: [message:Str]

    # Backend type bytes.
    B_AUTH = 'R'.ord
    B_BACKEND_KEY = 'K'.ord
    B_READY = 'Z'.ord
    B_COMMAND_COMPLETE = 'C'.ord
    B_ERROR = 'E'.ord
    B_ROW_DESCRIPTION = 'T'.ord
    B_ROW_DESCRIPTION_TYPED = 'y'.ord # protocol 1.1 (typed columns)
    B_DATA_ROW = 'D'.ord
    B_COPY_IN = 'G'.ord   # CopyInResponse (§12.1)
    B_COPY_OUT = 'H'.ord  # CopyOutResponse (§12.2)
    B_COPY_DATA = 'd'.ord # a COPY data chunk
    B_COPY_DONE = 'c'.ord # end of the COPY data stream
    B_NOTIFICATION = 'A'.ord # async LISTEN/NOTIFY: [pid:u32][channel:str][payload:str]

    # Column type tags carried by RowDescriptionTyped (protocol 1.1, wire-protocol.md §9.2). Maps the
    # 1-byte tag to a canonical type name; an unknown/0x00 tag is UNKNOWN (treated as text).
    TYPE_TAGS = {
      0x00 => 'UNKNOWN', 0x01 => 'BOOL', 0x02 => 'INT', 0x03 => 'FLOAT', 0x04 => 'NUMERIC',
      0x05 => 'TEXT', 0x06 => 'BYTES', 0x07 => 'DATE', 0x08 => 'TIME', 0x09 => 'TIMETZ',
      0x0A => 'TIMESTAMP', 0x0B => 'TIMESTAMPTZ', 0x0C => 'INTERVAL', 0x0D => 'UUID',
      0x0E => 'JSON', 0x0F => 'ARRAY', 0x10 => 'VECTOR'
    }.freeze

    # Canonical type name for a RowDescriptionTyped type tag (UNKNOWN if unrecognised).
    def self.type_name(tag)
      TYPE_TAGS.fetch(tag, 'UNKNOWN')
    end

    # Auth sub-codes.
    AUTH_OK = 0
    AUTH_SASL = 10
    AUTH_SASL_CONTINUE = 11
    AUTH_SASL_FINAL = 12

    module_function

    def u16(value)
      [value].pack('n')
    end

    def u32(value)
      [value].pack('N')
    end

    def str(value)
      bytes = value.to_s.dup.force_encoding(Encoding::BINARY)
      u32(bytes.bytesize) + bytes
    end

    # Encode a Fields list: [count:u16] then per field present byte + optional [len][bytes].
    def fields(values)
      out = u16(values.length)
      values.each do |v|
        if v.nil?
          out += "\x00".b
        else
          v = v.dup.force_encoding(Encoding::BINARY)
          out += "\x01".b + u32(v.bytesize) + v
        end
      end
      out
    end

    def frame(type, payload)
      total = payload.bytesize + HEADER_LEN
      (type.chr + u32(total) + payload).force_encoding(Encoding::BINARY)
    end

    def startup(user, database)
      payload = u32(MAGIC) + u16(MAJOR) + u16(MINOR) + str(user) + str(database)
      frame(T_STARTUP, payload)
    end

    def query(sql)
      frame(T_QUERY, str(sql))
    end

    def parse(name, sql)
      frame(T_PARSE, str(name) + str(sql) + u16(0))
    end

    def bind(portal, statement, values)
      frame(T_BIND, str(portal) + str(statement) + fields(values) + u16(0))
    end

    def describe_portal(name)
      frame(T_DESCRIBE, 'P'.b + str(name))
    end

    def execute(portal, max_rows = 0)
      frame(T_EXECUTE, str(portal) + u32(max_rows))
    end

    def sync
      frame(T_SYNC, ''.b)
    end

    def terminate
      frame(T_TERMINATE, ''.b)
    end

    def sasl_initial(mechanism, data)
      frame(T_SASL_INITIAL, str(mechanism) + u32(data.bytesize) + data)
    end

    def sasl_response(data)
      frame(T_SASL_RESPONSE, data)
    end

    def copy_data(data)
      frame(T_COPY_DATA, data)
    end

    def copy_done
      frame(T_COPY_DONE, ''.b)
    end

    def copy_fail(message)
      frame(T_COPY_FAIL, str(message))
    end
  end

  # Reads the protocol's primitive encodings from a payload buffer.
  class Reader
    def initialize(buf)
      @buf = buf
      @pos = 0
    end

    def u8
      v = @buf.getbyte(@pos)
      @pos += 1
      v
    end

    def u16
      v = @buf.byteslice(@pos, 2).unpack1('n')
      @pos += 2
      v
    end

    def u32
      v = @buf.byteslice(@pos, 4).unpack1('N')
      @pos += 4
      v
    end

    def str
      n = u32
      s = @buf.byteslice(@pos, n)
      @pos += n
      s.force_encoding(Encoding::UTF_8)
    end

    def rest
      s = @buf.byteslice(@pos, @buf.bytesize - @pos)
      @pos = @buf.bytesize
      s
    end

    # Decode a Fields list; a nil entry is SQL NULL.
    def fields
      n = u16
      out = []
      n.times do
        if u8.zero?
          out << nil
        else
          len = u32
          out << @buf.byteslice(@pos, len)
          @pos += len
        end
      end
      out
    end
  end
end
