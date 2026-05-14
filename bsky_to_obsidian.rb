#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "open3"
require "rbconfig"

Options = Struct.new(
  :config_path,
  keyword_init: true
)

def parse_options
  options = Options.new(
    config_path: "config.yml"
  )

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby bsky_to_obsidian.rb [--config config.yml]"

    opts.on("--config PATH", "Config file, default: config.yml") do |v|
      options.config_path = v
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

  run_command(ruby, "extract_car.rb", "--config", options.config_path)
  run_command(ruby, "insert_obsidian.rb", "--config", options.config_path)

  puts "bsky to obsidian complete"
end

main if $PROGRAM_NAME == __FILE__
