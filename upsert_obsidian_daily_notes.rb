#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require "date"
require "optparse"
require "fileutils"

require_relative "lib/config"
require_relative "lib/obsidian_block"
require_relative "lib/reply_filter"

Post = Struct.new(
  :path,
  :rkey,
  :created_at,
  :text,
  keyword_init: true
)

Options = Struct.new(
  :config_path,
  :input_path,
  :vault_path,
  :timezone,
  :daily_path_format,
  :exclude_texts,
  keyword_init: true
)

def parse_options
  options = Options.new(
    config_path: DEFAULT_CONFIG_PATH
  )

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby upsert_obsidian_daily_notes.rb [--config #{DEFAULT_CONFIG_PATH}]"

    opts.on("--config PATH", "Config file, default: #{DEFAULT_CONFIG_PATH}") do |v|
      options.config_path = v
    end
  end

  parser.parse!

  config = load_config(options.config_path)

  out_dir = config_get(config, "extract", "out_dir", default: "out")

  posts_jsonl = File.join(out_dir, "posts.jsonl")
  records_jsonl = File.join(out_dir, "records.jsonl")

  options.input_path =
    if File.exist?(posts_jsonl)
      posts_jsonl
    else
      records_jsonl
    end

  options.vault_path = config_get(config, "obsidian", "vault_path")
  options.timezone = config_get(config, "obsidian", "timezone", default: "Asia/Tokyo")

  options.daily_path_format = config_get(
    config,
    "obsidian",
    "daily",
    "path_format",
    default: "Daily/%Y-%m-%d.md"
  )

  options.exclude_texts = string_list_config(
    config_get(config, "obsidian", "posts", "exclude_texts", default: [])
  )

  unless options.vault_path && !options.vault_path.empty?
    warn "obsidian.vault_path is required in #{options.config_path}"
    exit 1
  end

  unless File.exist?(options.input_path)
    warn "input file not found: #{options.input_path}"
    warn "run extract_car.rb first"
    exit 1
  end

  options
end

def string_list_config(value)
  case value
  when nil
    []
  when Array
    value.map { |item| item.to_s.strip }.reject(&:empty?)
  else
    [value.to_s.strip].reject(&:empty?)
  end
end

def with_timezone(timezone)
  old_tz = ENV["TZ"]
  ENV["TZ"] = timezone
  yield
ensure
  ENV["TZ"] = old_tz
end

def local_time(time, timezone)
  with_timezone(timezone) do
    time.localtime
  end
end

def local_date(time, timezone)
  local_time(time, timezone).to_date
end

def daily_note_path(vault_path, path_format, date)
  relative_path = date.strftime(path_format)
  File.join(vault_path, relative_path)
end

def link_uri_from_facet(facet)
  features = facet["features"]
  return nil unless features.is_a?(Array)

  link = features.find { |feature| feature["$type"] == "app.bsky.richtext.facet#link" }
  link && link["uri"].to_s
end

def expand_faceted_links(text, facets)
  return text unless facets.is_a?(Array) && !facets.empty?

  replacements = facets.filter_map do |facet|
    index = facet["index"]
    next unless index.is_a?(Hash)

    uri = link_uri_from_facet(facet)
    next if uri.nil? || uri.empty?

    byte_start = index["byteStart"]
    byte_end = index["byteEnd"]
    next unless byte_start.is_a?(Integer) && byte_end.is_a?(Integer)
    next unless byte_start >= 0 && byte_end > byte_start && byte_end <= text.bytesize

    [byte_start, byte_end, uri]
  end

  return text if replacements.empty?

  bytes = text.b
  cursor = 0
  expanded = +""

  replacements.sort_by(&:first).each do |byte_start, byte_end, uri|
    next if byte_start < cursor

    expanded << bytes.byteslice(cursor...byte_start).force_encoding(Encoding::UTF_8)
    expanded << uri
    cursor = byte_end
  end

  expanded << bytes.byteslice(cursor..).to_s.force_encoding(Encoding::UTF_8)
  expanded
end

def excluded_post_text?(text, exclude_texts)
  exclude_texts.any? { |exclude_text| text.include?(exclude_text) }
end

def read_posts(path, exclude_texts)
  posts = []

  File.foreach(path, encoding: "UTF-8") do |line|
    line = line.strip
    next if line.empty?

    item = JSON.parse(line)

    next unless item["collection"] == "app.bsky.feed.post"

    record = item.fetch("record")

    type = record["$type"]
    next unless type == "app.bsky.feed.post"
    next if ReplyFilter.reply_to_other_user?(record, item["repo_did"])

    text = expand_faceted_links(record["text"].to_s, record["facets"])
    created_at = record["createdAt"]

    next if created_at.nil? || created_at.empty?
    next if excluded_post_text?(text, exclude_texts)

    posts << Post.new(
      path: item["path"],
      rkey: item["rkey"],
      created_at: Time.iso8601(created_at),
      text: text
    )
  end

  posts
    .uniq { |post| post.path || "#{post.created_at.iso8601}:#{post.text}" }
    .sort_by(&:created_at)
end

def normalize_post_text(text)
  text
    .gsub("\r\n", "\n")
    .gsub("\r", "\n")
    .gsub(/^([ \t]*)- \[ \] /, '\1- ')
    .rstrip
end

def render_posts_body(posts, timezone)
  return "<!-- no bluesky posts -->" if posts.empty?

  lines = []

  posts.sort_by(&:created_at).each do |post|
    time = local_time(post.created_at, timezone).strftime("%H:%M")
    text = normalize_post_text(post.text)

    lines << ["`#{time}`", text].join("\n")
  end

  lines.join("\n\n")
end

def read_or_create_daily_note(path)
  if File.exist?(path)
    File.read(path, encoding: "UTF-8")
  else
    FileUtils.mkdir_p(File.dirname(path))
    ""
  end
end

def write_daily_note(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content, encoding: "UTF-8")
end

def update_daily_note(path, posts, options)
  note = read_or_create_daily_note(path)

  body = render_posts_body(posts, options.timezone)
  updated = ObsidianBlock.replace_or_append(note, body)

  if updated == note
    :unchanged
  else
    write_daily_note(path, updated)
    :updated
  end
end

def main
  options = parse_options

  posts = read_posts(options.input_path, options.exclude_texts)

  posts_by_date = posts.group_by do |post|
    local_date(post.created_at, options.timezone)
  end

  updated = 0
  unchanged = 0
  skipped = 0

  posts_by_date.keys.sort.each do |date|
    path = daily_note_path(
      options.vault_path,
      options.daily_path_format,
      date
    )

    result = update_daily_note(path, posts_by_date.fetch(date), options)

    case result
    when :updated
      updated += 1
      puts "updated: #{path}"
    when :unchanged
      unchanged += 1
    when :skipped
      skipped += 1
      puts "skipped: #{path}"
    end
  end

  puts "posts: #{posts.size}"
  puts "daily notes updated: #{updated}"
  puts "daily notes unchanged: #{unchanged}"
  puts "daily notes skipped: #{skipped}"
end

main if $PROGRAM_NAME == __FILE__
