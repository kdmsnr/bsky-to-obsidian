#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "digest"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

require_relative "../x_to_obsidian"

def assert_equal(expected, actual, message)
  return if expected == actual

  raise "#{message}: expected #{expected.inspect}, got #{actual.inspect}"
end

def assert_raises(message)
  begin
    yield
  rescue StandardError
    return
  end
  raise "#{message}: expected an error"
end

def feed_item(id, date:, body:, author: "self", host: "x.com")
  <<~XML
    <item>
      <title>truncated title…</title>
      <link>https://#{host}/#{author}/status/#{id}</link>
      <guid>https://#{host}/#{author}/status/#{id}</guid>
      <pubDate>#{date}</pubDate>
      <description>#{CGI.escapeHTML(body)}</description>
    </item>
  XML
end

def feed(*items)
  %(<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel>#{items.join}</channel></rss>)
end

def run_script(script, *args)
  Open3.capture3(RbConfig.ruby, File.expand_path("../#{script}", __dir__), *args)
end

date = "Sat, 19 Sep 2026 15:05:00 GMT"
first = feed_item("100", date: date, body: "<p>日本語 &amp; &lt;記録&gt;<br />\n次の行</p><p><a href='https://example.com/full'>短いリンク…</a></p>")
second = feed_item("101", date: "Sat, 19 Sep 2026 15:10:00 GMT", body: "<p>新しい投稿</p>")
repost = feed_item("102", date: date, body: "<p>他人の投稿</p>", author: "someone")
parsed = XFeed.parse(feed(first)).first
assert_equal("日本語 & <記録>\n次の行\n\n短いリンク… (https://example.com/full)", parsed.fetch("text"), "HTML, entities, newlines and full links survive")
assert_equal("2026-09-19T15:05:00Z", parsed.fetch("created_at"), "RSS time is normalized to UTC")
assert_equal("literal <text>", XFeed.parse(feed("<item><title>literal &lt;text&gt;</title><link>https://x.com/self/status/1</link><pubDate>#{date}</pubDate></item>")).first.fetch("text"), "plain title fallback is not parsed as HTML")
assert_raises("HTML responses are rejected") { XFeed.parse("<html><body>Unavailable</body></html>") }
assert_raises("malformed XML is rejected") { XFeed.parse("<rss><channel>") }
assert_raises("missing dates are rejected") { XFeed.parse(feed(first.sub(/<pubDate>.*?<\/pubDate>/, ""))) }

Dir.mktmpdir("x-to-obsidian-test") do |directory|
  archive = File.join(directory, "archive")
  XFeed.archive(feed(first, repost), archive)
  changed = feed_item("100", date: date, body: "<p>編集した投稿</p>", host: "fxtwitter.com")
  XFeed.archive(feed(changed, second), archive)
  posts = XFeed.read_archive(archive)
  assert_equal(3, posts.size, "feed rollover retains history and status IDs prevent duplicates")
  assert_equal("編集した投稿", posts.find { |post| post["id"] == "100" }.fetch("text"), "existing posts are updated")
  XFeed.archive(feed(changed, second), archive)
  assert_equal(["latest.xml"], Dir.children(File.join(archive, "feeds")), "only the latest snapshot is retained")
  assert_equal(feed(changed, second).b, File.binread(File.join(archive, "feeds", "latest.xml")), "the latest raw XML is retained exactly")
  assert_equal(posts, XFeed.archive(feed, archive), "an empty feed preserves old posts")
  original_archive = File.binread(File.join(archive, "posts.jsonl"))
  original_snapshot = File.binread(File.join(archive, "feeds", "latest.xml"))
  assert_raises("invalid feeds fail before changing history") { XFeed.archive("<html/>", archive) }
  assert_equal(original_archive, File.binread(File.join(archive, "posts.jsonl")), "failed parsing leaves archive intact")
  assert_equal(original_snapshot, File.binread(File.join(archive, "feeds", "latest.xml")), "failed parsing leaves the latest snapshot intact")

  vault = File.join(directory, "vault")
  config = {
    "x" => { "handle" => "@SELF", "archive_dir" => archive },
    "extract" => { "out_dir" => File.join(directory, "out") },
    "obsidian" => {
      "vault_path" => vault,
      "timezone" => "Asia/Tokyo",
      "daily" => { "path_format" => "Daily/%Y/%Y-%m-%d.md" }
    }
  }
  config_path = File.join(directory, "config.yml")
  File.write(config_path, YAML.dump(config))
  path = File.join(vault, "Daily/2026/2026-09-20.md")
  FileUtils.mkdir_p(File.dirname(path))
  bsky_block = "<!-- bsky-to-obsidian:start -->\n`00:07`\nBluesky 本文\n<!-- bsky-to-obsidian:end -->"
  File.write(path, "# 手書き\n\n#{bsky_block}\n\nメモ\n")

  _stdout, stderr, status = run_script("x_to_obsidian.rb", "--config", config_path, "--offline")
  assert_equal(true, status.success?, "X-only CLI works without a CAR or feed URL: #{stderr}")
  note = File.read(path)
  assert_equal(true, note.include?(bsky_block), "X updates preserve the Bluesky block")
  assert_equal(true, note.include?("# 手書き") && note.include?("メモ"), "X updates preserve handwritten content")
  assert_equal(true, note.include?("`00:05` [X](https://x.com/self/status/100)\n編集した投稿"), "local date and time are used")
  assert_equal(false, note.include?("他人の投稿"), "reposts by other authors are not written")
  assert_equal(true, note.index("編集した投稿") < note.index("新しい投稿"), "posts are ordered within the X block")
  _stdout, stderr, status = run_script("x_to_obsidian.rb", "--config", config_path, "--offline")
  assert_equal(true, status.success?, "second import succeeds: #{stderr}")
  assert_equal(note, File.read(path), "repeat imports leave notes unchanged")

  out = config.fetch("extract").fetch("out_dir")
  FileUtils.mkdir_p(out)
  File.write(File.join(out, "records.jsonl"), JSON.generate({
    "path" => "app.bsky.feed.post/example", "collection" => "app.bsky.feed.post", "rkey" => "example",
    "record" => { "$type" => "app.bsky.feed.post", "text" => "Bluesky 更新", "createdAt" => "2026-09-19T15:07:00Z" }
  }) + "\n")
  x_block = note[/<!-- x-to-obsidian:start -->.*?<!-- x-to-obsidian:end -->/m]
  _stdout, stderr, status = run_script("upsert_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(true, status.success?, "Bluesky import succeeds: #{stderr}")
  assert_equal(true, File.read(path).include?(x_block), "Bluesky updates preserve the X block")
  _stdout, stderr, status = run_script("delete_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(true, status.success?, "Bluesky deletion succeeds: #{stderr}")
  assert_equal(true, File.read(path).include?(x_block), "Bluesky deletion preserves the X block")

  config["obsidian"]["posts"] = { "exclude_texts" => ["投稿"] }
  File.write(config_path, YAML.dump(config))
  _stdout, stderr, status = run_script("x_to_obsidian.rb", "--config", config_path, "--offline")
  assert_equal(true, status.success?, "exclusion update succeeds: #{stderr}")
  assert_equal(false, File.read(path).include?("<!-- x-to-obsidian:start -->"), "excluding all posts removes the old X block")
  assert_equal(posts, XFeed.read_archive(archive), "exclusion does not delete history")

  feed_path = File.join(directory, "saved.xml")
  File.write(feed_path, feed(feed_item("103", date: date, body: "<p>保存済みファイル</p>")))
  _stdout, stderr, status = run_script("x_to_obsidian.rb", "--config", config_path, "--feed-file", feed_path)
  assert_equal(true, status.success?, "saved RSS import succeeds: #{stderr}")
  assert_equal(4, XFeed.read_archive(archive).size, "saved RSS merges with history")
  note = File.read(path)
  File.write(feed_path, "<html>unavailable</html>")
  _stdout, _stderr, status = run_script("x_to_obsidian.rb", "--config", config_path, "--feed-file", feed_path)
  assert_equal(false, status.success?, "invalid feed CLI exits with failure")
  assert_equal(note, File.read(path), "invalid feed does not change daily notes")
  _stdout, _stderr, status = run_script("x_to_obsidian.rb", "--config", config_path, "--offline", "--feed-file", feed_path)
  assert_equal(false, status.success?, "conflicting CLI options are rejected")
end

Dir.mktmpdir("x-feed-migration-test") do |archive|
  current = feed_item("100", date: date, body: "<p>保存済みの編集</p>")
  XFeed.archive(feed(current), archive)
  snapshots = File.join(archive, "feeds")
  legacy_paths = [feed(first, repost), feed(second)].map do |xml|
    path = File.join(snapshots, "#{Digest::SHA256.hexdigest(xml)}.xml")
    File.binwrite(path, xml)
    path
  end
  File.write(File.join(snapshots, "manual.xml"), "unrelated file")
  corrupt_path = File.join(snapshots, "#{'a' * 64}.xml")
  File.write(corrupt_path, "<rss>")
  original_archive = File.binread(File.join(archive, "posts.jsonl"))
  original_snapshot = File.binread(File.join(snapshots, "latest.xml"))

  assert_raises("unreadable legacy snapshots prevent destructive cleanup") { XFeed.archive(feed(second), archive) }
  assert_equal(original_archive, File.binread(File.join(archive, "posts.jsonl")), "failed migration preserves history")
  assert_equal(original_snapshot, File.binread(File.join(snapshots, "latest.xml")), "failed migration preserves the latest snapshot")
  assert_equal(true, legacy_paths.all? { |path| File.exist?(path) }, "failed migration preserves old snapshots")
  File.delete(corrupt_path)

  posts = XFeed.archive(feed(second), archive)
  assert_equal(%w[100 101 102], posts.map { |post| post.fetch("id") }.sort, "posts from old snapshots are recovered before cleanup")
  assert_equal("保存済みの編集", posts.find { |post| post["id"] == "100" }.fetch("text"), "legacy snapshots do not overwrite existing history")
  assert_equal(["latest.xml", "manual.xml"], Dir.children(snapshots).sort, "cleanup removes only managed legacy snapshots")
  assert_equal(feed(second).b, File.binread(File.join(snapshots, "latest.xml")), "migration retains the incoming raw feed")

  3.times do |index|
    XFeed.archive(feed(feed_item((200 + index).to_s, date: date, body: "<p>#{index}</p>")), archive)
  end
  assert_equal(["latest.xml", "manual.xml"], Dir.children(snapshots).sort, "different feeds do not accumulate snapshot files")
  assert_equal(6, XFeed.read_archive(archive).size, "all posts survive snapshot replacement")
end

Dir.mktmpdir("x-days-boundary-test") do |directory|
  timestamps = %w[
    2026-09-13T14:59:59Z
    2026-09-13T15:00:00Z
    2026-09-19T14:59:59Z
    2026-09-19T15:00:00Z
    2026-09-20T14:59:59Z
    2026-09-20T15:00:00Z
  ]
  xml = feed(*timestamps.each_with_index.map do |timestamp, index|
    feed_item(index.to_s, date: Time.iso8601(timestamp).rfc2822, body: "<p>#{timestamp}</p>")
  end)
  archive = File.join(directory, "archive")
  posts = XFeed.archive(xml, archive)
  now = Time.iso8601("2026-09-19T15:30:00Z")

  [[7, "Asia/Tokyo", [1, 2, 3, 4]], [1, "Asia/Tokyo", [3, 4]], [1, "UTC", [2, 3]]].each do |days, timezone, expected|
    vault = Dir.mktmpdir("vault-", directory)
    config = {
      "x" => { "handle" => "self" },
      "obsidian" => { "vault_path" => vault, "timezone" => timezone, "posts" => { "days" => days } }
    }
    original_stdout = $stdout
    begin
      $stdout = StringIO.new
      XToObsidian.write_notes(posts, config, now: now)
    ensure
      $stdout = original_stdout
    end
    notes = Dir.glob(File.join(vault, "Daily/*.md")).map { |path| File.read(path) }.join
    timestamps.each_with_index do |timestamp, index|
      assert_equal(expected.include?(index), notes.include?(timestamp), "#{days} days in #{timezone}: calendar boundary for #{timestamp}")
    end
    assert_equal(posts, XFeed.read_archive(archive), "date filtering preserves posts outside the window in history")
  end

  # Exercise archive creation through the CLI with a limited writing window.
  today = Time.now.getlocal("+09:00").to_date
  dated_items = [today - 10, today].each_with_index.map do |day, index|
    feed_item(index.to_s, date: Time.iso8601("#{day}T12:00:00+09:00").rfc2822, body: "<p>#{day}</p>")
  end
  feed_path = File.join(directory, "feed.xml")
  File.write(feed_path, feed(*dated_items))
  config = {
    "x" => { "handle" => "self", "archive_dir" => File.join(directory, "cli-archive") },
    "obsidian" => { "vault_path" => File.join(directory, "cli-vault"), "timezone" => "Asia/Tokyo", "posts" => { "days" => 1 } }
  }
  config_path = File.join(directory, "config.yml")
  File.write(config_path, YAML.dump(config))
  _stdout, stderr, status = run_script("x_to_obsidian.rb", "--config", config_path, "--feed-file", feed_path)
  assert_equal(true, status.success?, "limited feed import succeeds: #{stderr}")
  assert_equal(2, XFeed.read_archive(config["x"]["archive_dir"]).size, "limited feed import archives every post")
  assert_equal(["#{today}.md"], Dir.glob(File.join(config["obsidian"]["vault_path"], "Daily/*.md")).map { |path| File.basename(path) }, "limited feed import writes only today's note")
end

puts "x_to_obsidian_test: ok"
