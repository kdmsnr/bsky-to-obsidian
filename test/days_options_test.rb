#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "time"
require "yaml"

def assert_equal(expected, actual, message)
  return if expected == actual

  raise "#{message}: expected #{expected.inspect}, got #{actual.inspect}"
end

repo_root = File.expand_path("..", __dir__)
today = Time.now.getlocal("+09:00").to_date
dates = [today - 10, today - 6, today - 1, today]

Dir.mktmpdir("bsky-days-test-") do |dir|
  out_dir = File.join(dir, "out")
  FileUtils.mkdir_p(out_dir)
  records = dates.map do |date|
    {
      "collection" => "app.bsky.feed.post",
      "path" => "app.bsky.feed.post/#{date}",
      "record" => {
        "$type" => "app.bsky.feed.post",
        "createdAt" => "#{date}T12:00:00+09:00",
        "text" => "Post for #{date}"
      }
    }
  end
  File.write(File.join(out_dir, "records.jsonl"), records.map { |record| JSON.generate(record) }.join("\n"))

  x_archive = File.join(dir, "x-archive")
  FileUtils.mkdir_p(x_archive)
  x_posts = records.each_with_index.map do |item, index|
    {
      "id" => index.to_s, "author" => "self", "url" => "https://x.com/self/status/#{index}",
      "created_at" => Time.iso8601(item["record"]["createdAt"]).utc.iso8601,
      "text" => item["record"]["text"]
    }
  end
  x_jsonl = x_posts.map { |post| JSON.generate(post) }.join("\n")
  File.write(File.join(x_archive, "posts.jsonl"), x_jsonl)

  ["bsky_to_obsidian.rb", "upsert_obsidian_daily_notes.rb", "x_to_obsidian.rb"].each do |script|
    x_script = script == "x_to_obsidian.rb"
    source = x_script ? "x" : "bsky"
    input_args = script == "upsert_obsidian_daily_notes.rb" ? [] : ["--offline"]
    cases = [
      [{}, [], dates],
      [{ "days" => 7 }, [], dates[1..]],
      [{ "days" => 1 }, [], [today]],
      [{ "days" => 7 }, ["--days", "1"], [today]],
      [{ "days" => 1 }, ["--days=7"], dates[1..]]
    ]

    cases.each do |posts_config, args, expected_dates|
      vault = Dir.mktmpdir("vault-", dir)
      original_notes = dates.to_h do |date|
        note = "# My note\n\n<!-- #{source}-to-obsidian:start -->\nOld log\n<!-- #{source}-to-obsidian:end -->\n"
        path = File.join(vault, "#{date}.md")
        File.write(path, note)
        File.utime(Time.at(946684800), Time.at(946684800), path)
        [date, [note, File.mtime(path)]]
      end
      config = {
        "x" => { "handle" => "self", "archive_dir" => x_archive },
        "extract" => { "out_dir" => out_dir },
        "obsidian" => {
          "vault_path" => vault,
          "timezone" => "Asia/Tokyo",
          "daily" => { "path_format" => "%Y-%m-%d.md" },
          "posts" => posts_config
        }
      }
      config_path = File.join(dir, "config.yml")
      File.write(config_path, YAML.dump(config))
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, File.join(repo_root, script), "--config", config_path, *input_args, *args, chdir: dir
      )
      raise "#{script} failed: #{stdout}\n#{stderr}" unless status.success?
      assert_equal(x_jsonl, File.read(File.join(x_archive, "posts.jsonl")), "day limits preserve the complete X archive") if x_script

      dates.each do |date|
        path = File.join(vault, "#{date}.md")
        note = File.read(path)
        if expected_dates.include?(date)
          assert_equal(true, note.include?("Post for #{date}"), "#{script}: updates #{date}")
          assert_equal(true, note.start_with?("# My note\n"), "#{script}: preserves personal notes")
        else
          original_note, original_mtime = original_notes.fetch(date)
          assert_equal(original_note, note, "#{script}: preserves out-of-range content")
          assert_equal(original_mtime, File.mtime(path), "#{script}: does not write out-of-range notes")
        end
      end
    end

    # Invalid options must fail before loading input or starting the pipeline.
    invalid_cases = [
      [{}, ["--days", "0"]],
      [{}, ["--days", "-1"]],
      [{}, ["--days", "1.5"]],
      [{}, ["--days", "abc"]],
      [{}, ["--days"]],
      [{ "days" => 0 }, []],
      [{ "days" => -1 }, []],
      [{ "days" => 1.5 }, []],
      [{ "days" => "7" }, []],
      [{ "days" => false }, []]
    ]
    invalid_cases.each do |posts_config, args|
      config_path = File.join(dir, "invalid.yml")
      File.write(config_path, YAML.dump({ "obsidian" => { "posts" => posts_config } }))
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, File.join(repo_root, script), "--config", config_path, *args, chdir: dir
      )
      assert_equal(false, status.success?, "#{script}: rejects invalid days")
      assert_equal(true, stderr.include?("days"), "#{script}: reports the invalid days option")
    end
  end
end

puts "days_options_test: ok"
