#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "open3"
require "rbconfig"

require_relative "lib/config"

Options = Struct.new(
  :config_path,
  :days,
  keyword_init: true
)

def parse_options
  options = Options.new(
    config_path: DEFAULT_CONFIG_PATH
  )

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby bsky_to_obsidian.rb [--config #{DEFAULT_CONFIG_PATH}] [--days N]"

    opts.on("--config PATH", "Config file, default: #{DEFAULT_CONFIG_PATH}") do |v|
      options.config_path = v
    end

    opts.on("--days N", Integer, "Sync the last N calendar days, including today") do |v|
      raise OptionParser::InvalidArgument, "--days must be a positive integer" unless v.positive?

      options.days = v
    end
  end

  parser.parse!
  options
end

def run_command(*cmd)
  puts "$ #{cmd.join(" ")}"

  success = false

  Open3.popen2e(*cmd) do |_stdin, stdout_and_stderr, wait_thread|
    stdout_and_stderr.each do |line|
      print line
    end

    success = wait_thread.value.success?
  end

  unless success
    warn "command failed: #{cmd.join(" ")}"
    exit 1
  end
end

def main
  options = parse_options
  ruby = RbConfig.ruby
  config = load_config(options.config_path)
  days = sync_days_config(config, override: options.days)
  handle = config_get(config, "bluesky", "handle")

  run_command(ruby, "download_car.rb", "--config", options.config_path) if handle && !handle.empty?
  run_command(ruby, "extract_car.rb", "--config", options.config_path)
  upsert_args = [ruby, "upsert_obsidian_daily_notes.rb", "--config", options.config_path]
  upsert_args += ["--days", days.to_s] if days
  run_command(*upsert_args)

  puts "bsky to obsidian complete"
end

main if $PROGRAM_NAME == __FILE__
