require "yaml"

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
