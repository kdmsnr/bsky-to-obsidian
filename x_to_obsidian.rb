#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

require_relative "lib/config"
require_relative "lib/script_runner"
require_relative "lib/x_feed"

module XToObsidian
  module_function

  def required_config(config, *keys)
    value = config_get(config, *keys).to_s.strip
    raise ArgumentError, "#{keys.join('.')} is required" if value.empty?

    value
  end

  def feed_url(config)
    configured_url = config_get(config, "x", "feed_url").to_s.strip
    return configured_url unless configured_url.empty?

    handle = required_config(config, "x", "handle").delete_prefix("@")
    "https://fxtwitter.com/#{handle}/feed.xml"
  end

  def main(argv = ARGV)
    options = { config: DEFAULT_CONFIG_PATH }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby x_to_obsidian.rb [--config PATH] [--days N] [--offline | --feed-file PATH]"
      opts.on("--config PATH", "Config file, default: #{DEFAULT_CONFIG_PATH}") { |value| options[:config] = value }
      opts.on("--days N", Integer, "Sync the last N calendar days, including today") do |value|
        raise OptionParser::InvalidArgument, "--days must be a positive integer" unless value.positive?

        options[:days] = value
      end
      opts.on("--offline", "Write notes from the saved archive without fetching RSS") { options[:offline] = true }
      opts.on("--feed-file PATH", "Import a saved RSS file instead of fetching") { |value| options[:feed_file] = value }
    end
    parser.parse!(argv)
    raise ArgumentError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    raise ArgumentError, "--offline and --feed-file cannot be combined" if options[:offline] && options[:feed_file]

    config = load_config(options[:config])
    days = sync_days_config(config, override: options[:days])
    required_config(config, "obsidian", "vault_path")
    required_config(config, "x", "handle")
    directory = config_get(config, "x", "archive_dir", default: "x-archive")
    posts = if options[:offline]
              XFeed.read_archive(directory)
            else
              xml = if options[:feed_file]
                      File.binread(options[:feed_file])
                    else
                      XFeed.fetch(feed_url(config))
                    end
              XFeed.archive(xml, directory)
            end

    puts "archived X posts: #{posts.size}"
    args = ["--config", options[:config], "--source", "x"]
    args += ["--days", days.to_s] if days
    ScriptRunner.run("upsert_obsidian_daily_notes.rb", *args)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    XToObsidian.main
  rescue StandardError => e
    warn "X import failed: #{e.message}"
    exit 1
  end
end
