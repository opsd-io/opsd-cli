# frozen_string_literal: true

# Copied Ruby runtimes may reference their build prefix and package-manager
# libraries. Keep non-system dependencies in runtime/lib; leave the platform's
# core loader/C runtime alone to preserve the operating system's ABI contract.
require "fileutils"
require "open3"
require "pathname"
require "rbconfig"

runtime = Pathname(ARGV.fetch(0)).expand_path
original_prefix = Pathname(ARGV.fetch(1)).expand_path
lib = runtime.join("lib")
macos = RbConfig::CONFIG.fetch("host_os").include?("darwin")
linux = RbConfig::CONFIG.fetch("host_os").include?("linux")
abort "Unsupported portable runtime OS" unless macos || linux

run = lambda do |*args|
  output, error, status = Open3.capture3(*args)
  abort "#{args.first} failed for #{args.last}: #{error}" unless status.success?
  output
end

queue = runtime.glob("**/*").select do |path|
  next false unless path.file? && !path.symlink?

  if macos
    path == runtime.join("bin/ruby") || %w[.dylib .bundle].include?(path.extname)
  else
    path.binread(4) == "\x7fELF"
  end
end
seen = {}
modified = []
until queue.empty?
  binary = queue.shift
  next if seen[binary.to_s]

  seen[binary.to_s] = true
  dependencies = if macos
                   run.call("otool", "-L", binary.to_s).lines.drop(1).filter_map { |line| line.strip.split(" (", 2).first }
                 else
                   output, = Open3.capture3("ldd", binary.to_s)
                   output.lines.filter_map { |line| line[/=> (\/\S+)/, 1] }
                 end
  dependencies.each do |dependency|
    next if macos && dependency.start_with?("/usr/lib/", "/System/Library/")
    next if linux && File.basename(dependency).match?(/\A(?:(?:libc|libm|libpthread|libdl|librt|libresolv)\.so|libc\.musl-|ld-linux|ld-musl)/)
    if macos && dependency.start_with?("@rpath/")
      target = lib.join(File.basename(dependency))
      abort "Unresolved runtime dependency: #{dependency} in #{binary}" unless target.file?
    else
      next unless dependency.start_with?("/")

      source = Pathname(dependency)
      target = if source.to_s.start_with?(original_prefix.to_s + "/")
                 runtime.join(source.relative_path_from(original_prefix))
               else
                 lib.join(source.basename)
               end
    end
    unless target.file?
      abort "Runtime dependency not found: #{source}" unless source.file?
      FileUtils.cp(source.realpath, target)
      queue << target
    end
    if macos
      relative = target.relative_path_from(binary.dirname)
      binary.chmod(binary.stat.mode | 0o200)
      run.call("install_name_tool", "-change", dependency, "@loader_path/#{relative}", binary.to_s)
      modified << binary
    end
  end
end
# Mach-O load-command edits invalidate signatures, including ad-hoc signatures.
modified.uniq.each { |binary| run.call("codesign", "--force", "--sign", "-", binary.to_s) } if macos
