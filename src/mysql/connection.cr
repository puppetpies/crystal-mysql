module MySQL
  # MySQL connection class. Allows high-level interaction with mysql
  # through LibMySQL.
  #
  # NOTE:
  # The @handle is totally not threadsafe, because it is stateful. So if
  # concurrency is needed, then each concurrent task should own its own
  # connection.
  class Connection
    struct ValueReader
      property value :: Types::SqlType
      property start

      def initialize(@value, @start)
      end

      def initialize
        @value = ""
        @start = 0
      end
    end

    def initialize
      @handle = LibMySQL.init(nil)
      @connected = false
    end

    def client_info
      String.new LibMySQL.client_info
    end

    def error
      String.new LibMySQL.error(@handle)
    end

    def connect(host, user, pass, db, port, socket, flags = 0_u32)
      handle = LibMySQL.real_connect(@handle, host, user, pass, db, port, socket,
                                     flags)
      if handle == @handle
        @connected = true
      elsif handle.nil?
        raise Errors::Connection.new(error)
      else
        raise Errors::Connection.new("Unreachable code")
      end

      self
    end

    def start_transaction
      query(%{START TRANSACTION})
    end

    def commit_transaction
      query(%{COMMIT})
    end

    def rollback_transaction
      query(%{ROLLBACK})
    end

    def transaction
      start_transaction
      yield
      commit_transaction
    rescue transaction_error
      begin
        rollback_transaction
      rescue rollback_error
        raise Errors::UnableToRollbackTransaction.new(transaction_error, rollback_error)
      end
      raise transaction_error
    end

    def close
      LibMySQL.close(@handle)
      @connected = nil
    end

    # @non-threadsafe!
    def query(query_string)
      unless @connected
        raise Errors::NotConnected.new
      end

      code = LibMySQL.query(@handle, query_string)
      raise Errors::Query.new(error, query_string) if code != 0
      result = LibMySQL.store_result(@handle)
      return nil if result.nil?

      fields = [] of LibMySQL::MySQLField
      while field = LibMySQL.fetch_field(result)
        fields << field.value
      end

      rows = [] of Array(Types::SqlType)
      while row = fetch_row(result, fields)
        rows << row
      end

      # NOTE: Why this happens here:
      # *** Error in `/tmp/crystal-run-spec.CAKQ1K': double free or corruption (out): 0x00000000008fa040 ***
      # NOTE: Probably because if result is already exhausted, it just frees itself
      #       That means, that this thing is only useful for #lazy_query
      #LibMySQL.free_result(result)

      rows
    end

    def fetch_row(result, fields)
      row = LibMySQL.fetch_row(result)
      return nil if row.nil?

      _lengths = LibMySQL.fetch_lengths(result)
      lengths = [] of UInt32
      fields.each_with_index do |x, index|
        lengths << _lengths[index * 2]
      end

      reader = ValueReader.new
      row_list = [] of Types::SqlType
      index = 0
      fields.each do |field|
        reader = fetch_value(field, row, reader, lengths[index])
        row_list << reader.value
        index += 1
      end

      row_list
    end

    def fetch_value(field, source, reader, len)
      value = Support.string_from_uint8(source[0] + reader.start, len)

      account_for_zero = 1

      parsed_value = value

      if field.field_type == LibMySQL::MySQLFieldType::MYSQL_TYPE_TIMESTAMP ||
          field.field_type == LibMySQL::MySQLFieldType::MYSQL_TYPE_DATETIME
        parsed_value = TimeFormat.new("%F %T").parse(value)
      end

      if field.field_type == LibMySQL::MySQLFieldType::MYSQL_TYPE_DATE && value.is_a?(String)
        parsed_value = TimeFormat.new("%F").parse(value)
      end

      if Types::INTEGER_TYPES.includes?(field.field_type)
        parsed_value = value.to_i
      end

      if Types::FLOAT_TYPES.includes?(field.field_type)
        parsed_value = value.to_f
      end

      if field.field_type == LibMySQL::MySQLFieldType::MYSQL_TYPE_BIT
        parsed_value = 0_i64
        value.each_char do |char|
          parsed_value *= 256
          parsed_value += char.ord
        end
      end

      if field.field_type == LibMySQL::MySQLFieldType::MYSQL_TYPE_NULL
        parsed_value = nil
        account_for_zero = 0
      end

      reader.start += len + account_for_zero
      reader.value = parsed_value
      reader
    end
  end
end
