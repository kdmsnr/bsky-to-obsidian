# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "nokogiri"
require "tempfile"
require "time"
require "uri"

module XFeed
  module_function

  def fetch(url, redirects: 5)
    uri = URI(url)
    raise ArgumentError, "feed URL must use HTTP or HTTPS" unless uri.is_a?(URI::HTTP) && uri.host

    response = Net::HTTP.start(
      uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30
    ) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "bsky-to-obsidian/1.0"
      http.request(request)
    end

    case response
    when Net::HTTPSuccess
      response.body
    when Net::HTTPRedirection
      raise "too many RSS redirects" if redirects.zero?
      raise "RSS redirect has no Location" unless response["location"]

      fetch(URI.join(url, response["location"]).to_s, redirects: redirects - 1)
    else
      raise "GET #{url} failed: #{response.code} #{response.message}"
    end
  end

  def html_text(node)
    return node.text.gsub(/[\t\r\n ]+/, " ") if node.text?
    return "" if node.comment? || %w[script style].include?(node.name)
    return "\n" if node.name == "br"
    return node["alt"].to_s if node.name == "img"

    text = node.children.map { |child| html_text(child) }.join
    if node.name == "a"
      href = node["href"].to_s
      if href.match?(%r{\Ahttps?://}i)
        text = text.strip
        text = text.empty? || text == href ? href : "#{text} (#{href})"
      end
    end
    %w[p div blockquote li].include?(node.name) ? "\n#{text}\n" : text
  end

  def body_text(item)
    body = item.at_xpath("content:encoded", "content" => "http://purl.org/rss/1.0/modules/content/")&.text
    body = item.at_xpath("description")&.text if body.to_s.empty?
    return item.at_xpath("title")&.text.to_s if body.to_s.empty?

    html_text(Nokogiri::HTML.fragment(body))
      .lines.map(&:strip).join("\n").gsub(/\n{3,}/, "\n\n").strip
  end

  def parse(xml)
    document = Nokogiri::XML(xml) { |config| config.strict.nonet }
    channel = document.at_xpath("/rss/channel")
    raise ArgumentError, "expected an RSS 2.0 feed" unless channel

    channel.xpath("item").map do |item|
      link = item.at_xpath("link")&.text.to_s.strip
      link = item.at_xpath("guid")&.text.to_s.strip if link.empty?
      uri = URI(link)
      status = uri.path.match(%r{\A/([A-Za-z0-9_]+)/status/(\d+)/?\z})
      unless uri.is_a?(URI::HTTP) && uri.host && status
        raise ArgumentError, "RSS item has no X status URL: #{link.inspect}"
      end

      date = item.at_xpath("pubDate")&.text.to_s
      raise ArgumentError, "RSS item has no pubDate: #{link}" if date.empty?

      {
        "id" => status[2],
        "author" => status[1],
        "url" => "https://x.com/#{status[1]}/status/#{status[2]}",
        "created_at" => Time.rfc2822(date).utc.iso8601,
        "text" => body_text(item)
      }
    end
  end

  def read_archive(directory)
    path = File.join(directory, "posts.jsonl")
    raise "X archive not found: #{path}; fetch RSS first" unless File.file?(path)

    File.foreach(path, encoding: "UTF-8").filter_map do |line|
      JSON.parse(line) unless line.strip.empty?
    end
  end

  def atomic_write(path)
    Tempfile.create([".#{File.basename(path)}", ".tmp"], File.dirname(path)) do |file|
      file.binmode
      yield file
      file.close
      File.rename(file.path, path)
    end
  end

  def archive(xml, directory)
    incoming = parse(xml)
    FileUtils.mkdir_p(directory)

    File.open(File.join(directory, ".lock"), "a") do |lock|
      lock.flock(File::LOCK_EX)
      path = File.join(directory, "posts.jsonl")
      existing = File.exist?(path) ? read_archive(directory) : []
      snapshots = File.join(directory, "feeds")
      FileUtils.mkdir_p(snapshots)
      legacy_snapshots = Dir.children(snapshots)
        .grep(/\A[0-9a-f]{64}\.xml\z/)
        .map { |name| File.join(snapshots, name) }
        .select { |snapshot| File.file?(snapshot) }
        .sort_by { |snapshot| [File.mtime(snapshot), snapshot] }

      # Recover any posts in old snapshots before deleting those files.
      # Existing history and the incoming feed take precedence over old copies.
      posts = {}
      legacy_snapshots.each do |snapshot|
        parse(File.binread(snapshot)).each { |post| posts[post.fetch("id")] = post }
      end
      (existing + incoming).each { |post| posts[post.fetch("id")] = post }
      posts = posts.values.sort_by { |post| [post.fetch("created_at"), post.fetch("id")] }

      atomic_write(path) do |file|
        posts.each { |post| file.puts(JSON.generate(post)) }
      end
      atomic_write(File.join(snapshots, "latest.xml")) { |file| file.write(xml) }
      legacy_snapshots.each { |snapshot| File.delete(snapshot) }

      posts
    end
  end
end
