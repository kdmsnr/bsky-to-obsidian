#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/reply_filter"

def build_record(root_did: nil, parent_did: nil)
  reply = {}
  reply["root"] = { "uri" => "at://#{root_did}/app.bsky.feed.post/root" } if root_did
  reply["parent"] = { "uri" => "at://#{parent_did}/app.bsky.feed.post/parent" } if parent_did

  { "reply" => reply }
end

def assert_equal(expected, actual, message)
  return if expected == actual

  raise "#{message}: expected #{expected.inspect}, got #{actual.inspect}"
end

repo_did = "did:plc:self"

assert_equal(false, ReplyFilter.reply_to_other_user?({}, repo_did), "non-replies stay included")
assert_equal(
  false,
  ReplyFilter.reply_to_other_user?(build_record(root_did: repo_did, parent_did: repo_did), repo_did),
  "direct replies to self stay included"
)
assert_equal(
  true,
  ReplyFilter.reply_to_other_user?(build_record(root_did: repo_did, parent_did: "did:plc:other"), repo_did),
  "replies to others in your own thread are excluded"
)
assert_equal(
  false,
  ReplyFilter.reply_to_other_user?(build_record(root_did: "did:plc:other", parent_did: repo_did), repo_did),
  "replies to your own post in someone else's thread stay included"
)
assert_equal(
  false,
  ReplyFilter.reply_to_other_user?(build_record(root_did: repo_did), repo_did),
  "root falls back when parent metadata is missing"
)

puts "reply_filter_test: ok"
