#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "lib/obsidian_notes"

module DeleteObsidianDailyNotes
  module_function

  def main(argv = ARGV)
    options = { config: DEFAULT_CONFIG_PATH }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby delete_obsidian_daily_notes.rb [--config PATH]"
      opts.on("--config PATH", "Config file, default: #{DEFAULT_CONFIG_PATH}") { |value| options[:config] = value }
    end
    parser.parse!(argv)
    raise ArgumentError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

    removed = ObsidianNotes.delete(load_config(options[:config]))
    puts "daily notes removed: #{removed}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    DeleteObsidianDailyNotes.main
  rescue StandardError => e
    warn "Obsidian deletion failed: #{e.message}"
    exit 1
  end
end
