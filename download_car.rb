#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "optparse"
require "uri"

require_relative "lib/config"

Options = Struct.new(
  :config_path,
  :handle,
  :car_path,
  keyword_init: true
)

def parse_options
  options = Options.new(
    config_path: DEFAULT_CONFIG_PATH
  )

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby download_car.rb [--config #{DEFAULT_CONFIG_PATH}]"

    opts.on("--config PATH", "Config file, default: #{DEFAULT_CONFIG_PATH}") do |v|
      options.config_path = v
    end
  end

  parser.parse!

  config = load_config(options.config_path)

  options.handle = config_get(config, "bluesky", "handle")
  options.car_path = config_get(config, "extract", "car_path", default: "repo.car")

  unless options.handle && !options.handle.empty?
    warn "bluesky.handle is required in #{options.config_path}"
    exit 1
  end

  options
end

def get_json(uri)
  response = Net::HTTP.get_response(uri)

  unless response.is_a?(Net::HTTPSuccess)
    raise "GET #{uri} failed: #{response.code} #{response.message}"
  end

  JSON.parse(response.body)
end

def resolve_handle(handle)
  uri = URI("https://bsky.social/xrpc/com.atproto.identity.resolveHandle")
  uri.query = URI.encode_www_form("handle" => handle)

  body = get_json(uri)
  did = body["did"]

  raise "failed to resolve handle: #{handle}" if did.nil? || did.empty?

  did
end

def download_repo(did, path)
  uri = URI("https://bsky.social/xrpc/com.atproto.sync.getRepo")
  uri.query = URI.encode_www_form("did" => did)

  response = Net::HTTP.get_response(uri)

  unless response.is_a?(Net::HTTPSuccess)
    raise "GET #{uri} failed: #{response.code} #{response.message}"
  end

  File.binwrite(path, response.body)
end

def main
  options = parse_options

  did = resolve_handle(options.handle)
  puts "resolved #{options.handle}: #{did}"

  download_repo(did, options.car_path)
  puts "wrote #{options.car_path}"
end

main if $PROGRAM_NAME == __FILE__
