#!/usr/bin/env ruby
# frozen_string_literal: true

require "cbor"
require "json"
require "optparse"
require "fileutils"
require "time"
require_relative "lib/config"

TARGET_COLLECTION = "app.bsky.feed.post"

Options = Struct.new(
  :config_path,
  :car_path,
  :out_dir,
  keyword_init: true
)

def parse_options
  options = Options.new(
    config_path: DEFAULT_CONFIG_PATH
  )

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby extract_car.rb [--config #{DEFAULT_CONFIG_PATH}]"

    opts.on("--config PATH", "Config file, default: #{DEFAULT_CONFIG_PATH}") do |v|
      options.config_path = v
    end
  end

  parser.parse!

  config = load_config(options.config_path)

  options.car_path = config_get(config, "extract", "car_path", default: "repo.car")
  options.out_dir = config_get(config, "extract", "out_dir", default: "out")

  unless File.exist?(options.car_path)
    warn "CAR file not found: #{options.car_path}"
    exit 1
  end

  options
end

def read_unsigned_varint(io)
  shift = 0
  result = 0

  loop do
    byte = io.read(1)
    raise EOFError, "unexpected EOF while reading varint" unless byte

    b = byte.getbyte(0)
    result |= (b & 0x7f) << shift

    return result if (b & 0x80).zero?

    shift += 7
    raise "varint too long" if shift > 63
  end
end

def read_unsigned_varint_from_string(str, offset)
  shift = 0
  result = 0

  loop do
    raise EOFError, "unexpected EOF while reading varint" if offset >= str.bytesize

    b = str.getbyte(offset)
    offset += 1

    result |= (b & 0x7f) << shift

    return [result, offset] if (b & 0x80).zero?

    shift += 7
    raise "varint too long" if shift > 63
  end
end

def read_cid_from_car_block(block)
  offset = 0

  version, offset = read_unsigned_varint_from_string(block, offset)
  raise "unsupported CID version: #{version}" unless version == 1

  _codec, offset = read_unsigned_varint_from_string(block, offset)
  _multihash_code, offset = read_unsigned_varint_from_string(block, offset)
  multihash_len, offset = read_unsigned_varint_from_string(block, offset)

  cid_len = offset + multihash_len
  raise "invalid CID length" if cid_len > block.bytesize

  cid = block.byteslice(0, cid_len)
  data = block.byteslice(cid_len..)

  [cid, data]
end

def read_car(path)
  blocks = {}

  File.open(path, "rb") do |io|
    header_len = read_unsigned_varint(io)
    header_raw = io.read(header_len)
    raise "failed to read CAR header" unless header_raw&.bytesize == header_len

    header = CBOR.decode(header_raw)

    until io.eof?
      len = read_unsigned_varint(io)
      raw = io.read(len)
      raise "failed to read CAR block" unless raw&.bytesize == len

      cid, data = read_cid_from_car_block(raw)
      blocks[cid] = data
    end

    [header, blocks]
  end
end

def hash_get(hash, key)
  hash[key] || hash[key.to_sym]
end

def cbor_tag?(obj, number)
  return false unless obj

  if obj.respond_to?(:tag)
    obj.tag == number
  elsif obj.respond_to?(:tag_number)
    obj.tag_number == number
  else
    false
  end
end

def cbor_tag_value(obj)
  if obj.respond_to?(:value)
    obj.value
  elsif obj.respond_to?(:content)
    obj.content
  else
    raise "unknown CBOR tag object: #{obj.class}: #{obj.inspect}"
  end
end

def cid_bytes_from_cbor_tag(obj)
  unless cbor_tag?(obj, 42)
    raise "expected CBOR tag 42 CID, got #{obj.class}: #{obj.inspect}"
  end

  value = cbor_tag_value(obj)

  unless value.is_a?(String)
    raise "expected CID tag value to be binary string, got #{value.class}"
  end

  # DAG-CBORのCID tag 42は、先頭に0x00を付けたbytesとして格納される。
  value.getbyte(0) == 0 ? value.byteslice(1..) : value
end

def cid_hex(cid_bytes)
  cid_bytes.unpack1("H*")
end

def decode_block(blocks, cid)
  raw = blocks[cid]
  raise "missing block for CID #{cid_hex(cid)}" unless raw

  CBOR.decode(raw)
end

def normalize_for_json(obj)
  case obj
  when Hash
    obj.each_with_object({}) do |(k, v), h|
      h[k.to_s] = normalize_for_json(v)
    end
  when Array
    obj.map { |v| normalize_for_json(v) }
  when String
    if obj.encoding == Encoding::ASCII_8BIT && !obj.valid_encoding?
      {
        "$bytes_hex" => obj.unpack1("H*")
      }
    else
      obj
    end
  else
    if cbor_tag?(obj, 42)
      {
        "$link" => cid_hex(cid_bytes_from_cbor_tag(obj))
      }
    elsif obj.respond_to?(:tag) || obj.respond_to?(:tag_number)
      {
        "$tag" => (obj.respond_to?(:tag) ? obj.tag : obj.tag_number),
        "value" => normalize_for_json(cbor_tag_value(obj))
      }
    else
      obj
    end
  end
end

def repo_root_from_commit(commit)
  data = hash_get(commit, "data")
  raise "commit block does not contain data root" unless data

  cid_bytes_from_cbor_tag(data)
end

def roots_from_header(header)
  roots = hash_get(header, "roots")
  raise "CAR header does not contain roots" unless roots && !roots.empty?

  roots.map { |root| cid_bytes_from_cbor_tag(root) }
end

def traverse_mst(blocks, root_cid, prefix = "", records = {})
  node = decode_block(blocks, root_cid)

  left = hash_get(node, "l")
  entries = hash_get(node, "e") || []

  traverse_mst(blocks, cid_bytes_from_cbor_tag(left), prefix, records) if left

  previous_key = prefix

  entries.each do |entry|
    p = hash_get(entry, "p") || 0
    k = hash_get(entry, "k")
    v = hash_get(entry, "v")
    t = hash_get(entry, "t")

    key_suffix = k.to_s
    key = previous_key.byteslice(0, p).to_s + key_suffix

    records[key] = cid_bytes_from_cbor_tag(v) if v
    traverse_mst(blocks, cid_bytes_from_cbor_tag(t), key, records) if t

    previous_key = key
  end

  records
end

def split_record_path(path)
  collection, rkey = path.split("/", 2)
  [collection, rkey]
end

def did_from_at_uri(uri)
  uri.to_s[%r{\Aat://([^/]+)/}, 1]
end

def own_reply?(record, repo_did)
  reply = record["reply"]
  return false unless reply && repo_did

  ["root", "parent"].any? do |key|
    did_from_at_uri(reply.dig(key, "uri")) == repo_did
  end
end

def reply_to_other_user?(record, repo_did)
  record["reply"] && !own_reply?(record, repo_did)
end

def safe_path_component(str)
  str.gsub(%r{[^A-Za-z0-9._:-]}, "_")
end

def record_year_month(item)
  record = item.fetch("record", {})
  created_at = record["createdAt"]

  return ["_unknown_date"] if created_at.nil? || created_at.empty?

  begin
    t = Time.iso8601(created_at).getlocal("+09:00")
    [t.strftime("%Y"), t.strftime("%m")]
  rescue ArgumentError
    ["_unknown_date"]
  end
end

def write_record_file(out_dir, item)
  collection = safe_path_component(item.fetch("collection"))
  rkey = safe_path_component(item.fetch("rkey"))

  date_parts = record_year_month(item)

  dir = File.join(out_dir, "records", collection, *date_parts)
  FileUtils.mkdir_p(dir)

  path = File.join(dir, "#{rkey}.json")
  File.write(path, JSON.pretty_generate(item) + "\n", encoding: "UTF-8")
end

def extract_records(options)
  header, blocks = read_car(options.car_path)

  commit_cid = roots_from_header(header).first
  commit = decode_block(blocks, commit_cid)
  repo_did = hash_get(commit, "did")
  mst_root_cid = repo_root_from_commit(commit)

  record_cids_by_path = traverse_mst(blocks, mst_root_cid)

  items = []

  record_cids_by_path.keys.sort.each do |path|
    collection, rkey = split_record_path(path)
    next unless collection == TARGET_COLLECTION

    record_cid = record_cids_by_path.fetch(path)
    record = decode_block(blocks, record_cid)
    normalized_record = normalize_for_json(record)
    next if reply_to_other_user?(normalized_record, repo_did)

    item = {
      "repo_did" => repo_did,
      "path" => path,
      "collection" => collection,
      "rkey" => rkey,
      "cid_hex" => cid_hex(record_cid),
      "type" => normalized_record["$type"],
      "record" => normalized_record
    }

    items << item
  end

  items
end

def main
  options = parse_options

  FileUtils.mkdir_p(options.out_dir)

  items = extract_records(options)

  jsonl_path = File.join(options.out_dir, "records.jsonl")

  File.open(jsonl_path, "w", encoding: "UTF-8") do |f|
    items.each do |item|
      f.puts(JSON.generate(item))
      write_record_file(options.out_dir, item)
    end
  end

  puts "wrote #{items.size} records"
  puts "jsonl: #{jsonl_path}"
  puts "files: #{File.join(options.out_dir, "records")}"
end

main if $PROGRAM_NAME == __FILE__
