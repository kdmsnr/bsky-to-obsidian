# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "set"
require "tempfile"
require "time"
require "uri"

module BskyFeed
  API = "https://public.api.bsky.app/xrpc"
  COLLECTION = "app.bsky.feed.post"

  module_function

  def get_json(method, params)
    uri = URI("#{API}/#{method}")
    uri.query = URI.encode_www_form(params)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "bsky-to-obsidian/1.0"
      http.request(request)
    end
    unless response.is_a?(Net::HTTPSuccess)
      raise "GET #{uri} failed: #{response.code} #{response.message}"
    end

    JSON.parse(response.body)
  end

  def resolve_actor(actor)
    return actor if actor.start_with?("did:")

    body = get_json("com.atproto.identity.resolveHandle", "handle" => actor.delete_prefix("@"))
    did = body.fetch("did")
    raise "invalid DID for #{actor}" unless did.is_a?(String) && did.start_with?("did:")

    did
  end

  # Keep the CAR record shape so the existing renderer can retain facets and replies.
  def normalize(item, did)
    raise "archive belongs to another account: #{item['repo_did'].inspect}" unless item["repo_did"] == did

    path = item.fetch("path")
    match = path.match(%r{\Aapp\.bsky\.feed\.post/([A-Za-z0-9._~:-]+)\z})
    raise "invalid Bluesky post path: #{path.inspect}" unless match

    record = item.fetch("record")
    unless record.is_a?(Hash) && record["$type"] == COLLECTION && record["text"].is_a?(String)
      raise "invalid Bluesky post: #{path}"
    end
    Time.iso8601(record.fetch("createdAt"))

    {
      "uri" => "at://#{did}/#{path}",
      "repo_did" => did,
      "path" => path,
      "collection" => COLLECTION,
      "rkey" => match[1],
      "record" => record
    }
  end

  def read_posts(path, did)
    File.foreach(path, encoding: "UTF-8").filter_map do |line|
      next if line.strip.empty?

      item = JSON.parse(line)
      next unless item["collection"] == COLLECTION

      normalize(item, did)
    end
  end

  def fetch_latest(did, known_uris:, request: method(:get_json))
    known = known_uris.to_set
    posts = []
    cursor = nil
    seen_cursors = Set.new

    loop do
      params = { "actor" => did, "limit" => 100, "filter" => "posts_with_replies", "includePins" => false }
      params["cursor"] = cursor if cursor
      body = request.call("app.bsky.feed.getAuthorFeed", params)
      feed = body.fetch("feed")
      raise "invalid author feed" unless feed.is_a?(Array)

      reached_history = false
      feed.each do |entry|
        post = entry.fetch("post")
        next unless post.fetch("author").fetch("did") == did

        uri = post.fetch("uri")
        prefix = "at://#{did}/"
        raise "post URI does not match its author: #{uri}" unless uri.start_with?(prefix)

        item = normalize({ "repo_did" => did, "path" => uri.delete_prefix(prefix), "record" => post.fetch("record") }, did)
        posts << item
        # An old self-repost must not stop pagination before intervening new posts.
        reached_history ||= known.include?(uri) && !entry["reason"]
      end

      # Consume the whole boundary page, including posts already in the archive.
      cursor = body["cursor"]
      break if reached_history || cursor.nil? || cursor == ""

      raise "invalid or repeated author feed cursor" unless cursor.is_a?(String) && seen_cursors.add?(cursor)
    end

    posts
  end

  def merge(existing, incoming)
    posts = {}
    (existing + incoming).each { |post| posts[post.fetch("uri")] = post }
    posts.values.sort_by { |post| [Time.iso8601(post.fetch("record").fetch("createdAt")), post.fetch("uri")] }
  end

  def write_archive(path, posts)
    FileUtils.mkdir_p(File.dirname(path))
    Tempfile.create([".posts", ".tmp"], File.dirname(path)) do |file|
      file.set_encoding("UTF-8")
      posts.each { |post| file.puts(JSON.generate(post)) }
      file.close
      File.rename(file.path, path)
    end
  end
end
