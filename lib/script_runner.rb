# frozen_string_literal: true

require "open3"
require "rbconfig"

module ScriptRunner
  module_function

  def run(script, *args)
    cmd = [RbConfig.ruby, File.expand_path("../#{script}", __dir__), *args]
    puts "$ #{cmd.join(' ')}"
    success = Open3.popen2e(*cmd) do |_stdin, output, wait_thread|
      output.each { |line| print line }
      wait_thread.value.success?
    end
    raise "command failed: #{script}" unless success
  end
end
