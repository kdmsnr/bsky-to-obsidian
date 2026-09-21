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
  repo_did: "did:plc:self",
  created_at: Time.iso8601("2024-09-25T16:44:55Z"),
  text: "- [ ] ジガルタンダ・ダブルX\n- [x] ソウルの春"
)

assert_equal(
  "`16:44` [Bluesky](https://bsky.app/profile/did:plc:self/post/example)\n- ジガルタンダ・ダブルX\n- [x] ソウルの春",
  render_posts_body([post], "UTC"),
  "rendered logs strip unchecked task markers"
)

now = Time.iso8601("2026-09-19T15:30:00Z") # September 20 in Asia/Tokyo
dated_posts = [
  "2026-09-13T14:59:59Z", # Just before the seven-day window in Asia/Tokyo
  "2026-09-13T15:00:00Z", # First day, midnight
  "2026-09-19T14:59:59Z", # Yesterday, 23:59:59
  "2026-09-19T15:00:00Z", # Today, midnight
  "2026-09-20T14:59:59Z", # Today, 23:59:59
  "2026-09-20T15:00:00Z"  # Tomorrow, midnight
].map { |timestamp| Post.new(created_at: Time.iso8601(timestamp), text: timestamp) }

assert_equal(
  dated_posts,
  filter_posts_by_days(dated_posts, nil, "Asia/Tokyo", now: now),
  "omitting days preserves the full input"
)
assert_equal(
  dated_posts[1..4],
  filter_posts_by_days(dated_posts, 7, "Asia/Tokyo", now: now),
  "seven days includes whole local dates and excludes tomorrow"
)
assert_equal(
  dated_posts[3..4],
  filter_posts_by_days(dated_posts, 1, "Asia/Tokyo", now: now),
  "one day includes only today in the configured timezone"
)
assert_equal(
  dated_posts[2..3],
  filter_posts_by_days(dated_posts, 1, "UTC", now: now),
  "today follows the configured timezone rather than the system timezone"
)

puts "upsert_obsidian_daily_notes_test: ok"
