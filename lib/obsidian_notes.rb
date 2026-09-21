# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "time"

require_relative "config"
require_relative "obsidian_block"
require_relative "reply_filter"

module ObsidianNotes
  LABELS = { bsky: "Bluesky", x: "X" }.freeze
  BLOCKS = { bsky: "bsky-to-obsidian", x: "x-to-obsidian" }.freeze
  Post = Struct.new(:id, :created_at, :text, :url, :eligible, keyword_init: true)

  module_function

  def required_config(config, *keys)
    value = config_get(config, *keys).to_s.strip
    raise ArgumentError, "#{keys.join('.')} is required" if value.empty?

    value
  end

  def with_timezone(timezone)
    old_tz = ENV["TZ"]
    ENV["TZ"] = timezone
    yield
  ensure
    ENV["TZ"] = old_tz
  end

  def local_time(time, timezone)
    with_timezone(timezone) { time.getlocal }
  end

  def filter_posts_by_days(posts, days, timezone, now: Time.now)
    return posts unless days

    today = local_time(now, timezone).to_date
    first_date = today - (days - 1)
    posts.select { |post| local_time(post.created_at, timezone).to_date.between?(first_date, today) }
  end

  def expand_faceted_links(text, facets)
    return text unless facets.is_a?(Array)

    replacements = facets.filter_map do |facet|
      index = facet["index"]
      features = facet["features"]
      next unless index.is_a?(Hash) && features.is_a?(Array)

      link = features.find { |feature| feature["$type"] == "app.bsky.richtext.facet#link" }
      uri = link && link["uri"].to_s
      next if uri.nil? || uri.empty?

      first = index["byteStart"]
      last = index["byteEnd"]
      next unless first.is_a?(Integer) && last.is_a?(Integer)
      next unless first >= 0 && last > first && last <= text.bytesize

      [first, last, uri]
    end

    bytes = text.b
    cursor = 0
    expanded = +""
    replacements.sort_by(&:first).each do |first, last, uri|
      next if first < cursor

      expanded << bytes.byteslice(cursor...first).force_encoding(Encoding::UTF_8)
      expanded << uri
      cursor = last
    end
    expanded << bytes.byteslice(cursor..).to_s.force_encoding(Encoding::UTF_8)
  end

  def read_jsonl(path)
    File.foreach(path, encoding: "UTF-8").filter_map do |line|
      JSON.parse(line) unless line.strip.empty?
    end
  end

  def read_bsky_posts(path)
    read_jsonl(path).filter_map do |item|
      next unless item["collection"] == "app.bsky.feed.post"

      record = item.fetch("record")
      next unless record["$type"] == "app.bsky.feed.post"
      next if record["createdAt"].to_s.empty?

      did = item["repo_did"]
      rkey = item["rkey"]
      url = if !did.to_s.empty? && !rkey.to_s.empty?
              "https://bsky.app/profile/#{did}/post/#{rkey}"
            end
      Post.new(
        id: item["uri"] || item["path"] || "#{record['createdAt']}:#{record['text']}",
        created_at: Time.iso8601(record["createdAt"]),
        text: expand_faceted_links(record["text"].to_s, record["facets"]),
        url: url,
        eligible: !ReplyFilter.reply_to_other_user?(record, did)
      )
    end.uniq(&:id)
  end

  def x_posts(records, config)
    handle = required_config(config, "x", "handle").delete_prefix("@")
    records.map do |record|
      Post.new(
        id: record.fetch("id"),
        created_at: Time.iso8601(record.fetch("created_at")),
        text: record.fetch("text"),
        url: record.fetch("url"),
        eligible: record.fetch("author").casecmp?(handle)
      )
    end.uniq(&:id)
  end

  def read_archives(config, sources: LABELS.keys)
    sources.each_with_object({}) do |source, posts|
      case source
      when :bsky
        directory = config_get(config, "extract", "out_dir", default: "out")
        path = %w[posts.jsonl records.jsonl].map { |name| File.join(directory, name) }.find { |candidate| File.file?(candidate) }
        posts[source] = read_bsky_posts(path) if path
      when :x
        next unless config_get(config, "x")

        directory = config_get(config, "x", "archive_dir", default: "x-archive")
        path = File.join(directory, "posts.jsonl")
        posts[source] = x_posts(read_jsonl(path), config) if File.file?(path)
      else
        raise ArgumentError, "unknown source: #{source}"
      end
    end
  end

  def normalize_post_text(text)
    text.gsub("\r\n", "\n").gsub("\r", "\n").gsub(/^([ \t]*)- \[ \] /, '\1- ').rstrip
  end

  def render(posts, source, timezone)
    posts.sort_by { |post| [post.created_at, post.id.to_s] }.map do |post|
      time = local_time(post.created_at, timezone).strftime("%H:%M")
      heading = "`#{time}`"
      heading += " [#{LABELS.fetch(source)}](#{post.url})" if post.url
      "#{heading}\n#{normalize_post_text(post.text)}"
    end.join("\n\n")
  end

  def write_archives(config, sources: LABELS.keys, days: nil, now: Time.now)
    days = sync_days_config(config, override: days)
    required_config(config, "obsidian", "vault_path")
    # Read every selected archive before changing any note.
    posts = read_archives(config, sources: sources)
    raise "no saved posts found; run an import first" if posts.empty?

    write(posts, config, days: days, now: now)
  end

  def write(posts_by_source, config, days: nil, now: Time.now)
    days = sync_days_config(config, override: days)
    vault = required_config(config, "obsidian", "vault_path")
    timezone = config_get(config, "obsidian", "timezone", default: "Asia/Tokyo")
    path_format = config_get(config, "obsidian", "daily", "path_format", default: "Daily/%Y-%m-%d.md")
    excludes = Array(config_get(config, "obsidian", "posts", "exclude_texts", default: []))
      .map { |text| text.to_s.strip }.reject(&:empty?)
    grouped = posts_by_source.transform_values do |posts|
      filter_posts_by_days(posts, days, timezone, now: now).group_by do |post|
        local_time(post.created_at, timezone).to_date
      end
    end

    updated_count = 0
    grouped.values.flat_map(&:keys).uniq.sort.each do |date|
      path = File.join(vault, date.strftime(path_format))
      note = File.file?(path) ? File.read(path, encoding: "UTF-8") : ""
      updated = note
      grouped.each do |source, by_date|
        next unless by_date.key?(date)

        selected = by_date.fetch(date).select do |post|
          post.eligible != false && excludes.none? { |text| post.text.include?(text) }
        end
        updated = if selected.empty?
                    ObsidianBlock.remove(updated, name: BLOCKS.fetch(source)).first
                  else
                    ObsidianBlock.replace_or_append(updated, render(selected, source, timezone), name: BLOCKS.fetch(source))
                  end
      end
      next if updated == note

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, updated, encoding: "UTF-8")
      updated_count += 1
      puts "updated: #{path}"
    end
    updated_count
  end

  def delete(config)
    vault = required_config(config, "obsidian", "vault_path")
    raise "vault directory not found: #{vault}" unless File.directory?(vault)

    removed_count = 0
    Dir.glob("**/*.md", base: vault).sort.each do |relative_path|
      path = File.join(vault, relative_path)
      next unless File.file?(path) && !File.symlink?(path)

      note = File.read(path, encoding: "UTF-8")
      updated = note
      BLOCKS.each_value do |name|
        loop do
          updated, changed = ObsidianBlock.remove(updated, name: name)
          break unless changed
        end
      end
      next if updated == note

      File.write(path, updated, encoding: "UTF-8")
      removed_count += 1
      puts "removed: #{path}"
    end
    removed_count
  end
end
