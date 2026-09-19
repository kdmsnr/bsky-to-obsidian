#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "optparse"

require_relative "lib/config"
require_relative "lib/obsidian_block"
require_relative "lib/x_feed"

module XToObsidian
  BLOCK_NAME = "x-to-obsidian"

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

  def render(posts)
    posts.map do |post|
      time = Time.iso8601(post.fetch("created_at")).getlocal.strftime("%H:%M")
      text = post.fetch("text").gsub("\r\n", "\n").gsub("\r", "\n")
      text = text.gsub(/^([ \t]*)- \[ \] /, '\1- ').rstrip
      "`#{time}` [X](#{post.fetch('url')})\n#{text}"
    end.join("\n\n")
  end

  def write_notes(posts, config, days: nil, now: Time.now)
    old_tz = ENV["TZ"]
    days = sync_days_config(config, override: days)
    vault = required_config(config, "obsidian", "vault_path")
    handle = required_config(config, "x", "handle").delete_prefix("@")
    path_format = config_get(config, "obsidian", "daily", "path_format", default: "Daily/%Y-%m-%d.md")
    excludes = Array(config_get(config, "obsidian", "posts", "exclude_texts", default: []))
      .map { |text| text.to_s.strip }.reject(&:empty?)

    ENV["TZ"] = config_get(config, "obsidian", "timezone", default: "Asia/Tokyo")
    today = now.getlocal.to_date
    first_date = today - (days - 1) if days
    by_date = posts.sort_by { |post| [post.fetch("created_at"), post.fetch("id")] }.group_by do |post|
      Time.iso8601(post.fetch("created_at")).getlocal.to_date
    end

    updated_count = 0
    by_date.each do |date, daily_posts|
      next if days && !date.between?(first_date, today)

      selected = daily_posts.select do |post|
        post.fetch("author").casecmp?(handle) && excludes.none? { |text| post.fetch("text").include?(text) }
      end
      path = File.join(vault, date.strftime(path_format))
      next if selected.empty? && !File.exist?(path)

      note = File.exist?(path) ? File.read(path, encoding: "UTF-8") : ""
      updated = if selected.empty?
                  ObsidianBlock.remove(note, name: BLOCK_NAME).first
                else
                  ObsidianBlock.replace_or_append(note, render(selected), name: BLOCK_NAME)
                end
      next if updated == note

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, updated, encoding: "UTF-8")
      updated_count += 1
      puts "updated: #{path}"
    end
    updated_count
  ensure
    ENV["TZ"] = old_tz
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
    puts "daily notes updated: #{write_notes(posts, config, days: days)}"
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
