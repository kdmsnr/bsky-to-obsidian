#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "lib/obsidian_notes"

module UpsertObsidianDailyNotes
  module_function

  def main(argv = ARGV)
    options = { config: DEFAULT_CONFIG_PATH, source: "all" }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby upsert_obsidian_daily_notes.rb [--config PATH] [--days N] [--source all|bsky|x]"
      opts.on("--config PATH", "Config file, default: #{DEFAULT_CONFIG_PATH}") { |value| options[:config] = value }
      opts.on("--days N", Integer, "Sync the last N calendar days, including today") do |value|
        raise OptionParser::InvalidArgument, "--days must be a positive integer" unless value.positive?

        options[:days] = value
      end
      opts.on("--source SOURCE", %w[all bsky x], "Source to write, default: all") { |value| options[:source] = value }
    end
    parser.parse!(argv)
    raise ArgumentError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

    config = load_config(options[:config])
    sources = options[:source] == "all" ? ObsidianNotes::LABELS.keys : [options[:source].to_sym]
    updated = ObsidianNotes.write_archives(config, sources: sources, days: options[:days])
    puts "daily notes updated: #{updated}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    UpsertObsidianDailyNotes.main
  rescue StandardError => e
    warn "Obsidian update failed: #{e.message}"
    exit 1
  end
end
