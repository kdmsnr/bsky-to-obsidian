#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../lib/obsidian_notes"

def assert_equal(expected, actual, message)
  return if expected == actual

  raise "#{message}: expected #{expected.inspect}, got #{actual.inspect}"
end

def run_script(directory, script, *args)
  Open3.capture3(RbConfig.ruby, File.expand_path("../#{script}", __dir__), *args, chdir: directory)
end

def write_jsonl(path, records)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, records.map { |record| JSON.generate(record) }.join("\n") + "\n")
end

Dir.mktmpdir("obsidian-notes-test") do |directory|
  vault = File.join(directory, "vault")
  bsky_path = File.join(directory, "out", "posts.jsonl")
  x_path = File.join(directory, "x-archive", "posts.jsonl")
  today = Time.now.getlocal("+09:00").to_date
  timestamp = "#{today}T00:05:00+09:00"
  bsky = {
    "repo_did" => "did:plc:self", "collection" => "app.bsky.feed.post",
    "path" => "app.bsky.feed.post/one", "rkey" => "one",
    "record" => { "$type" => "app.bsky.feed.post", "createdAt" => timestamp, "text" => "Bluesky 本文" }
  }
  x = { "id" => "1", "author" => "self", "created_at" => timestamp, "text" => "X 本文", "url" => "https://x.com/self/status/1" }
  config = {
    "extract" => { "out_dir" => File.dirname(bsky_path) },
    "x" => { "handle" => "self", "archive_dir" => File.dirname(x_path) },
    "obsidian" => { "vault_path" => vault, "timezone" => "Asia/Tokyo",
                    "daily" => { "path_format" => "Daily/%Y/%m/%Y-%m-%d.md" } }
  }
  config_path = File.join(directory, "config.yml")
  File.write(config_path, YAML.dump(config))
  path = File.join(vault, today.strftime(config["obsidian"]["daily"]["path_format"]))
  FileUtils.mkdir_p(File.dirname(path))
  manual = "# 手書き\n\nこの段落は保持する。\n"
  File.write(path, manual)
  write_jsonl(bsky_path, [bsky])
  write_jsonl(x_path, [x])
  originals = [bsky_path, x_path].to_h { |file| [file, File.binread(file)] }

  stdout, stderr, status = run_script(directory, "upsert_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(true, status.success?, "combined upsert succeeds: #{stderr}")
  assert_equal(1, stdout.lines.count { |line| line.start_with?("updated:") }, "both sources update the same note once")
  note = File.read(path)
  assert_equal(true, note.include?("Bluesky 本文") && note.include?("X 本文"), "both archives are written")
  assert_equal(true, note.include?("[Bluesky](https://bsky.app/profile/did:plc:self/post/one)"), "Bluesky links survive the shared writer")
  assert_equal(true, note.include?("[X](https://x.com/self/status/1)"), "X links survive the shared writer")
  assert_equal(true, note.start_with?(manual), "handwritten content is preserved")
  mtime = File.mtime(path)
  _stdout, stderr, status = run_script(directory, "upsert_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(true, status.success?, "repeated combined upsert succeeds: #{stderr}")
  assert_equal(mtime, File.mtime(path), "unchanged combined notes are not rewritten")

  # A bad second archive cannot leave notes partially updated by the first.
  bsky["record"]["text"] = "Bluesky 更新"
  write_jsonl(bsky_path, [bsky])
  File.write(x_path, "{broken")
  _stdout, _stderr, status = run_script(directory, "upsert_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(false, status.success?, "a corrupt archive fails the combined upsert")
  assert_equal(note, File.read(path), "all archives are parsed before changing notes")
  _stdout, stderr, status = run_script(directory, "upsert_obsidian_daily_notes.rb", "--config", config_path, "--source", "bsky")
  assert_equal(true, status.success?, "a source-specific import ignores the other archive: #{stderr}")
  assert_equal(true, File.read(path).include?("Bluesky 更新") && File.read(path).include?("X 本文"), "source selection preserves the other block")

  # Missing history is different from an empty set of selected posts.
  File.delete(x_path)
  _stdout, stderr, status = run_script(directory, "upsert_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(true, status.success?, "Bluesky-only history succeeds with X still configured: #{stderr}")
  assert_equal(true, File.read(path).include?("X 本文"), "missing X history never removes the existing X block")
  write_jsonl(x_path, [x])
  File.delete(bsky_path)
  _stdout, stderr, status = run_script(directory, "upsert_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(true, status.success?, "X-only history needs no CAR: #{stderr}")
  assert_equal(true, File.read(path).include?("Bluesky 更新"), "missing Bluesky history preserves its block")

  # Excluding every post on a date clears stale managed content for both sources.
  write_jsonl(bsky_path, [bsky])
  config["obsidian"]["posts"] = { "exclude_texts" => ["Bluesky", "X 本文"] }
  File.write(config_path, YAML.dump(config))
  _stdout, stderr, status = run_script(directory, "upsert_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(true, status.success?, "exclusions apply to both archives: #{stderr}")
  assert_equal(manual, File.read(path), "excluded blocks are removed without deleting the note")
  assert_equal("Bluesky 更新", JSON.parse(File.read(bsky_path))["record"]["text"], "exclusions retain Bluesky history")
  assert_equal(originals.fetch(x_path), File.binread(x_path), "exclusions retain X history")
  config["obsidian"].delete("posts")
  File.write(config_path, YAML.dump(config))
  _stdout, stderr, status = run_script(directory, "upsert_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(true, status.success?, "saved histories can rebuild removed blocks: #{stderr}")

  archive_before_delete = [bsky_path, x_path].to_h { |file| [file, File.binread(file)] }
  _stdout, stderr, status = run_script(directory, "delete_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(true, status.success?, "combined deletion succeeds: #{stderr}")
  assert_equal(manual, File.read(path), "deletion removes both services and retains handwritten text")
  archive_before_delete.each { |file, bytes| assert_equal(bytes, File.binread(file), "deletion never changes saved history") }

  # Deletion also works after archives or path settings have changed.
  File.delete(bsky_path)
  File.delete(x_path)
  orphan = File.join(vault, "Old", "old-note.md")
  unrelated = File.join(vault, "plain.md")
  broken = File.join(vault, "incomplete.md")
  FileUtils.mkdir_p(File.dirname(orphan))
  bsky_block = "<!-- bsky-to-obsidian:start -->\n古い記録\n<!-- bsky-to-obsidian:end -->\n"
  x_block = "<!-- x-to-obsidian:start -->\n古い X\n<!-- x-to-obsidian:end -->\n"
  File.write(orphan, manual + bsky_block + x_block + bsky_block)
  File.write(unrelated, manual)
  File.write(broken, "<!-- bsky-to-obsidian:start -->\n手書きかもしれない未完のブロック\n")
  preserved = [unrelated, broken].to_h { |file| [file, [File.binread(file), File.mtime(file)]] }
  _stdout, stderr, status = run_script(directory, "delete_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(true, status.success?, "deletion needs neither archive: #{stderr}")
  assert_equal(manual, File.read(orphan), "all complete managed blocks are removed even outside the current daily path")
  preserved.each do |file, snapshot|
    assert_equal(snapshot, [File.binread(file), File.mtime(file)], "unrelated or incomplete blocks are not modified")
  end
  mtime = File.mtime(orphan)
  _stdout, stderr, status = run_script(directory, "delete_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(true, status.success?, "repeated deletion succeeds: #{stderr}")
  assert_equal(mtime, File.mtime(orphan), "repeated deletion does not rewrite files")
  _stdout, _stderr, status = run_script(directory, "upsert_obsidian_daily_notes.rb", "--config", config_path)
  assert_equal(false, status.success?, "upsert reports that no histories are available")
end

puts "obsidian_notes_test: ok"
