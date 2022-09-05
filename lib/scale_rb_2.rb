require 'scale_rb_2/version'

class String
  def to_bytes
    data = start_with?('0x') ? self[2..] : self
    raise 'Not valid hex string' if data =~ /[^\da-f]+/i

    data = "0#{data}" if data.length.odd?
    data.scan(/../).map(&:hex)
  end
end

class Integer
  def to_bytes
    to_s(16).to_bytes
  end
end

class Array
  def to_hex
    raise 'Not a byte array' unless byte_array?

    reduce('0x') { |hex, byte| hex + byte.to_s(16).rjust(2, '0') }
  end

  def to_bin
    raise 'Not a byte array' unless byte_array?

    reduce('0b') { |bin, byte| bin + byte.to_s(2).rjust(8, '0') }
  end

  def to_utf8
    raise 'Not a byte array' unless byte_array?

    pack('C*').force_encoding('utf-8')
  end

  def to_scale_uint
    reverse.to_hex.to_i(16)
  end

  def flip
    reverse
  end

  def byte_array?
    all? { |e| e >= 0 and e <= 255 }
  end
end
require 'scale_rb_2/version'

def array?(type)
  type[0] == '[' && type[type.length - 1] == ']'
end

def uint?(type)
  type[0] == 'u' && type[1..] =~ /\A(8|16|32|64|128|256|512)\z/
end

def vec?(type)
  type[0..3] == 'Vec<' && type[-1] == '>'
end

def struct?(type)
  type.instance_of?(Hash)
end

def enum?(type)
  type.instance_of?(Hash) && type.key?(:_enum)
end

def parse_fixed_array(type)
  scan_out = type.scan(/\A\[\s*(.+)\s*;\s*(\d+)\s*\]\z/)
  raise ScaleRb2::TypeParseError, type if scan_out.empty?
  raise ScaleRb2::TypeParseError, type if scan_out[0].length != 2

  inner_type = scan_out[0][0]
  length = scan_out[0][1].to_i
  [inner_type, length]
end

module ScaleRb2
  class Error < StandardError; end
  # decoding errors
  class NotImplemented < Error; end
  class TypeParseError < Error; end
  class NotEnoughBytesError < Error; end
  class Unreachable < Error; end
  class IndexOutOfRangeError < Error; end
  # encoding errors
  class LengthNotEqualErr < Error; end

  def self.decode(type, bytes)
    puts '============================================================================================================='
    puts "           type: #{type}"
    puts "          bytes: #{bytes}"
    value, remaining_bytes = do_decode(type, bytes)
    puts "        decoded: #{value}"
    puts "remaining bytes: #{remaining_bytes}"
    [value, remaining_bytes]
  end

  def self.do_decode(type, bytes)
    return decode_compact(bytes) if type == 'Compact'
    return decode_uint(type, bytes) if uint?(type) # u8, u16...
    return decode_array(type, bytes) if array?(type) # [u8; 3]
    return decode_vec(type, bytes) if vec?(type) # Vec<u8>
    return decode_enum(type, bytes) if enum?(type)
    return decode_struct(type, bytes) if struct?(type)

    raise NotImplemented
  end

  def self.decode_enum(enum, bytes)
    index = bytes[0]
    raise IndexOutOfRangeError, "type: #{enum}, bytes: #{bytes}" if index > enum[:_enum].length - 1

    key = enum[:_enum].keys[index]
    type = enum[:_enum].values[index]

    value, remaining_bytes = do_decode(type, bytes[1..])
    [{ key => value }, remaining_bytes]
  end

  def self.decode_struct(struct, bytes)
    if struct.empty?
      [{}, bytes]
    else
      key, type = struct.first
      value, remaining_bytes = do_decode(type, bytes)
      remaining_struct = struct.slice(*struct.keys[1..])
      values, remaining_bytes = decode_struct(remaining_struct, remaining_bytes)
      [
        { key => value }.merge(values),
        remaining_bytes
      ]
    end
  end

  def self.decode_types(types, bytes)
    if types.empty?
      [[], bytes]
    else
      value, remaining_bytes = encode(types[0], bytes)
      value_arr, remaining_bytes = decode_types(types[1..], remaining_bytes)
      [[value] + value_arr, remaining_bytes]
    end
  end

  def self.decode_compact(bytes)
    case bytes[0] & 3
    when 0
      [bytes[0] >> 2, bytes[1..]]
    when 1
      [bytes[0..1].to_scale_uint >> 2, bytes[2..]]
    when 2
      [bytes[0..3].to_scale_uint >> 2, bytes[4..]]
    when 3
      length = 4 + (bytes[0] >> 2)
      [bytes[1..length].to_scale_uint, bytes[length + 1..]]
    else
      raise Unreachable, "type: Compact, bytes: #{bytes}"
    end
  end

  def self.decode_array(type, bytes)
    inner_type, length = parse_fixed_array(type)
    decode_fixed_array(inner_type, length, bytes)
  end

  def self.decode_fixed_array(inner_type, length, bytes)
    if length >= 1
      value, remaining_bytes = do_decode(inner_type, bytes)
      arr, remaining_bytes = decode_fixed_array(inner_type, length - 1, remaining_bytes)
      [[value] + arr, remaining_bytes]
    else
      [[], bytes]
    end
  end

  def self.decode_vec(type, bytes)
    inner_type = type.scan(/\AVec<(.+)>\z/).first.first
    length, remaining_bytes = decode_compact(bytes)
    decode_fixed_array(inner_type, length, remaining_bytes)
  end

  def self.encode_array(type, array)
    inner_type, length = parse_fixed_array(type)
    raise LengthNotEqualErr, "type: #{type}, value: #{array}" if length != array.length

    encode_fixed_array(inner_type, array)
  end

  def self.encode_fixed_array(inner_type, array)
    if array.length >= 1
      bytes = do_encode(inner_type, array[0])
      bytes + encode_fixed_array(inner_type, array[1..])
    else
      []
    end
  end

  def self.decode_uint(type, bytes)
    bits_len = type[1..].to_i
    bytes_len = bits_len / 8
    raise NotEnoughBytesError, "type: #{type}, bytes: #{bytes}" if bytes.length < bytes_len

    [
      bytes[0...bytes_len].to_scale_uint,
      bytes[bytes_len..]
    ]
  end

  def self.encode_uint(type, value)
    bits_len = type[1..].to_i
    bytes_len = bits_len / 8
    hex = value.to_s(16).rjust(bytes_len * 2, '0')
    hex.to_bytes.flip
  end

  def self.encode(type, value)
    do_encode(type, value)
  end

  def self.do_encode(type, value)
    return encode_compact(value) if type == 'Compact'
    return encode_uint(type, value) if uint?(type)
    return encode_array(type, value) if array?(type)
    return encode_struct(type, value) if struct?(type)

    raise NotImplemented
  end

  def self.encode_compact(value)
    return [value << 2] if (value >= 0) && (value < 64)
    return ((value << 2) + 1).to_bytes.flip if value < 2**14
    return ((value << 2) + 2).to_bytes.flip if value < 2**30

    bytes = value.to_bytes.flip
    [(((bytes.length - 4) << 2) + 3)] + bytes
  end

  def self.encode_struct(type, value)
    type.keys.reduce([]) do |bytes, key|
      item_type = type[key]
      item_value = value[key]
      bytes + do_encode(item_type, item_value)
    end
  end
end
