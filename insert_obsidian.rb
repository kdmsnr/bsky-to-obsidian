#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require "date"
require "optparse"
require "fileutils"

require_relative "lib/config"

START_MARKER = "<!-- bsky-to-obsidian:start -->"
END_MARKER = "<!-- bsky-to-obsidian:end -->"

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
  :create_if_missing,
  keyword_init: true
)

def parse_options
  options = Options.new(
    config_path: "config.yml"
  )

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby insert_obsidian.rb [--config config.yml]"

    opts.on("--config PATH", "Config file, default: config.yml") do |v|
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

  options.create_if_missing = config_get(
    config,
    "obsidian",
    "daily",
    "create_if_missing",
    default: true
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

def read_posts(path)
  posts = []

  File.foreach(path, encoding: "UTF-8") do |line|
    line = line.strip
    next if line.empty?

    item = JSON.parse(line)

    collection = item["collection"]
    next unless collection.nil? || collection == "app.bsky.feed.post"

    record = item.fetch("record")

    type = record["$type"]
    next unless type.nil? || type == "app.bsky.feed.post"

    text = record["text"].to_s
    created_at = record["createdAt"]

    next if created_at.nil? || created_at.empty?

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

def escape_markdown_text(text)
  text
    .gsub("\r\n", "\n")
    .gsub("\r", "\n")
    .gsub("\n", "<br>")
end

def render_posts_body(posts, timezone)
  return "<!-- no bluesky posts -->" if posts.empty?

  lines = []

  posts.sort_by(&:created_at).each do |post|
    time = local_time(post.created_at, timezone).strftime("%H:%M")
    text = escape_markdown_text(post.text)

    lines << "- #{time} #{text}"

    if post.path && !post.path.empty?
      lines << "  - path: #{post.path}"
    end
  end

  lines.join("\n")
end

def replace_or_append_block(note, body)
  start_index = note.index(START_MARKER)
  end_index = note.index(END_MARKER)

  if start_index && end_index && end_index > start_index
    body_start = start_index + START_MARKER.length

    before = note[0...body_start].rstrip
    after = note[end_index..].to_s.lstrip

    [
      before,
      body.rstrip,
      after
    ].join("\n").rstrip + "\n"
  else
    [
      note.rstrip,
      "",
      START_MARKER,
      body.rstrip,
      END_MARKER
    ].join("\n").rstrip + "\n"
  end
end

def read_or_create_daily_note(path, create_if_missing)
  if File.exist?(path)
    File.read(path, encoding: "UTF-8")
  elsif create_if_missing
    FileUtils.mkdir_p(File.dirname(path))
    ""
  else
    nil
  end
end

def write_daily_note(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content, encoding: "UTF-8")
end

def update_daily_note(path, posts, options)
  note = read_or_create_daily_note(path, options.create_if_missing)
  return :skipped unless note

  body = render_posts_body(posts, options.timezone)
  updated = replace_or_append_block(note, body)

  if updated == note
    :unchanged
  else
    write_daily_note(path, updated)
    :updated
  end
end

def main
  options = parse_options

  posts = read_posts(options.input_path)

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
