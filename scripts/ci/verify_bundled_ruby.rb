# frozen_string_literal: true

require "rbconfig"
require "json"
require "yaml"
require "openssl"
require "open3"
require "fiddle"

root = File.realpath(ARGV.fetch(0)) + "/"
abort "Ruby executable escaped the bundle" unless File.realpath(RbConfig.ruby).start_with?(root)
escaped = $LOADED_FEATURES.grep(%r{^/}).reject { |path| File.realpath(path).start_with?(root) }
abort "Ruby loaded libraries outside the bundle: #{escaped.join(', ')}" unless escaped.empty?

# Checking loaded Ruby files alone can miss a copied executable still linking
# the original libruby or package-manager dependencies from the build machine.
if RUBY_PLATFORM.include?("darwin")
  handle = Fiddle::Handle::DEFAULT
  count = Fiddle::Function.new(handle["_dyld_image_count"], [], Fiddle::TYPE_INT).call
  image_name = Fiddle::Function.new(handle["_dyld_get_image_name"], [Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
  escaped = count.times.filter_map do |index|
    path = image_name.call(index).to_s
    next if path.start_with?("/usr/lib/", "/System/Library/")
    next if File.realpath(path).start_with?(root)

    path
  end
  abort "Native libraries escaped the bundle: #{escaped.join(', ')}" unless escaped.empty?
elsif File.file?("/proc/self/maps")
  ruby_libraries = File.readlines("/proc/self/maps").filter_map do |line|
    path = line.split(/\s+/, 6).last&.strip
    path if path&.include?("/libruby")
  end.uniq
  abort "libruby escaped the bundle" unless ruby_libraries.all? { |path| File.realpath(path).start_with?(root) }
end
