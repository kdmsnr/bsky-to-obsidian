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
  response = http_get(uri)

  unless response.is_a?(Net::HTTPSuccess)
    raise "GET #{uri} failed: #{response.code} #{response.message}"
  end

  JSON.parse(response.body)
end

def http_get(uri)
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
    request = Net::HTTP::Get.new(uri)
    http.request(request)
  end
end

def resolve_handle(handle)
  uri = URI("https://bsky.social/xrpc/com.atproto.identity.resolveHandle")
  uri.query = URI.encode_www_form("handle" => handle)

  body = get_json(uri)
  did = body["did"]

  raise "failed to resolve handle: #{handle}" if did.nil? || did.empty?

  did
end

def did_document_uri(did)
  case did
  when /\Adid:plc:[A-Za-z0-9]+\z/
    URI("https://plc.directory/#{did}")
  when /\Adid:web:/
    encoded_host = did.delete_prefix("did:web:")

    raise "path-based did:web is not supported: #{did}" if encoded_host.include?(":")

    host = URI.decode_www_form_component(encoded_host)
    raise "invalid did:web host: #{did}" if host.empty? || host.include?("/")

    scheme = host.start_with?("localhost") ? "http" : "https"

    URI("#{scheme}://#{host}/.well-known/did.json")
  else
    raise "unsupported DID method: #{did}"
  end
end

def resolve_pds_endpoint(did)
  uri = did_document_uri(did)
  body = get_json(uri)

  service = Array(body["service"]).find do |entry|
    entry["type"] == "AtprotoPersonalDataServer" && entry["id"].to_s.end_with?("#atproto_pds")
  end

  endpoint = service && service["serviceEndpoint"]

  raise "failed to resolve PDS endpoint for #{did}" if endpoint.nil? || endpoint.empty?

  endpoint
end

def download_repo(pds_endpoint, did, path)
  uri = URI("#{pds_endpoint}/xrpc/com.atproto.sync.getRepo")
  uri.query = URI.encode_www_form("did" => did)

  response = http_get(uri)

  unless response.is_a?(Net::HTTPSuccess)
    raise "GET #{uri} failed: #{response.code} #{response.message}"
  end

  File.binwrite(path, response.body)
end

def main
  options = parse_options

  did = resolve_handle(options.handle)
  pds_endpoint = resolve_pds_endpoint(did)

  puts "resolved #{options.handle}: #{did}"
  puts "resolved PDS: #{pds_endpoint}"

  download_repo(pds_endpoint, did, options.car_path)
  puts "wrote #{options.car_path}"
end

main if $PROGRAM_NAME == __FILE__
