#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require "date"
require "optparse"

require_relative "lib/config"
require_relative "lib/obsidian_block"
require_relative "lib/reply_filter"

Options = Struct.new(
  :config_path,
  :input_path,
  :vault_path,
  :timezone,
  :daily_path_format,
  keyword_init: true
)

def parse_options
  options = Options.new(config_path: DEFAULT_CONFIG_PATH)

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby delete_obsidian_daily_notes.rb [--config #{DEFAULT_CONFIG_PATH}]"

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

def local_date(time, timezone)
  with_timezone(timezone) do
    time.localtime.to_date
  end
end

def daily_note_path(vault_path, path_format, date)
  relative_path = date.strftime(path_format)
  File.join(vault_path, relative_path)
end

def read_target_dates(input_path, timezone)
  dates = []

  File.foreach(input_path, encoding: "UTF-8") do |line|
    line = line.strip
    next if line.empty?

    item = JSON.parse(line)

    next unless item["collection"] == "app.bsky.feed.post"

    record = item.fetch("record")
    type = record["$type"]
    next unless type == "app.bsky.feed.post"
    next if ReplyFilter.reply_to_other_user?(record, item["repo_did"])

    created_at = record["createdAt"]
    next if created_at.nil? || created_at.empty?

    dates << local_date(Time.iso8601(created_at), timezone)
  end

  dates.uniq.sort
end

def main
  options = parse_options

  dates = read_target_dates(options.input_path, options.timezone)

  removed = 0
  unchanged = 0
  missing = 0

  dates.each do |date|
    path = daily_note_path(
      options.vault_path,
      options.daily_path_format,
      date
    )

    unless File.exist?(path)
      missing += 1
      next
    end

    note = File.read(path, encoding: "UTF-8")
    updated, changed = ObsidianBlock.remove(note)

    if changed
      File.write(path, updated, encoding: "UTF-8")
      removed += 1
      puts "removed: #{path}"
    else
      unchanged += 1
    end
  end

  puts "daily notes removed: #{removed}"
  puts "daily notes unchanged: #{unchanged}"
  puts "daily notes missing: #{missing}"
end

main if $PROGRAM_NAME == __FILE__
