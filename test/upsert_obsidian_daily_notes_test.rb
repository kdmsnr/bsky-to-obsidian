#!/usr/bin/env ruby
# frozen_string_literal: true

require "time"

require_relative "../upsert_obsidian_daily_notes"

def assert_equal(expected, actual, message)
  return if expected == actual

  raise "#{message}: expected #{expected.inspect}, got #{actual.inspect}"
end

assert_equal(
  "TODO:\n- 講演スライドの校正\n  - 講義スライドの作成\n- [x] 年末調整",
  normalize_post_text("TODO:\r\n- [ ] 講演スライドの校正\r\n  - [ ] 講義スライドの作成\r\n- [x] 年末調整\r\n"),
  "unchecked task markers are rendered as plain bullets"
)

post = Post.new(
  path: "app.bsky.feed.post/example",
  rkey: "example",
  created_at: Time.iso8601("2024-09-25T16:44:55Z"),
  text: "- [ ] ジガルタンダ・ダブルX\n- [x] ソウルの春"
)

assert_equal(
  "`16:44`\n- ジガルタンダ・ダブルX\n- [x] ソウルの春",
  render_posts_body([post], "UTC"),
  "rendered logs strip unchecked task markers"
)

puts "upsert_obsidian_daily_notes_test: ok"
