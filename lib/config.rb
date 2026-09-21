require "yaml"
require "uri"

DEFAULT_CONFIG_PATH = "config.yml"

def load_config(path = DEFAULT_CONFIG_PATH)
  unless File.exist?(path)
    warn "config file not found: #{path}"
    exit 1
  end

  YAML.load_file(path) || {}
end

def config_get(config, *keys, default: nil)
  current = config

  keys.each do |key|
    return default unless current.is_a?(Hash)

    current = current[key.to_s] || current[key.to_sym]
  end

  current.nil? ? default : current
end

def sync_days_config(config, override: nil)
  days = override || config.dig("obsidian", "posts", "days")
  return days if days.nil? || (days.is_a?(Integer) && days.positive?)

  raise ArgumentError, "obsidian.posts.days must be a positive integer"
end

def bluesky_actor_config(config)
  feed_url = config_get(config, "bluesky", "feed_url").to_s.strip
  unless feed_url.empty?
    begin
      uri = URI(feed_url)
    rescue URI::InvalidURIError
      raise ArgumentError, "bluesky.feed_url must be https://bsky.app/profile/<DID-or-handle>/rss"
    end
    match = uri.path&.match(%r{\A/profile/([^/]+)/rss/?\z})
    unless uri.is_a?(URI::HTTPS) && uri.host == "bsky.app" && uri.port == 443 &&
           !uri.userinfo && !uri.query && !uri.fragment && match
      raise ArgumentError, "bluesky.feed_url must be https://bsky.app/profile/<DID-or-handle>/rss"
    end

    actor = URI::DEFAULT_PARSER.unescape(match[1])
    raise ArgumentError, "invalid account in bluesky.feed_url" unless actor.match?(/\A[A-Za-z0-9._:%-]+\z/)

    return actor
  end

  %w[did handle].each do |key|
    actor = config_get(config, "bluesky", key).to_s.strip
    return actor unless actor.empty?
  end
  raise ArgumentError, "bluesky.feed_url, bluesky.did or bluesky.handle is required"
end
