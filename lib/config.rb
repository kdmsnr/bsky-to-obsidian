require "yaml"

def load_config(path = "config.yml")
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
