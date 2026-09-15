#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "rbconfig"
require "shellwords"
require "yaml"

repo_root = Pathname(__dir__).join("..").realpath
$LOAD_PATH.unshift(repo_root.join("lib").to_s)

require "opsd/module_catalog"
require "opsd/template_store"

def run!(env, command, chdir: nil)
  location = chdir ? " (cwd: #{chdir})" : ""
  puts "$ #{Shellwords.join(command)}#{location}"

  success =
    if chdir
      system(env, *command, chdir: chdir)
    else
      system(env, *command)
    end
  return if success

  raise "Command failed with exit status #{$?.exitstatus}: #{Shellwords.join(command)}"
end

def run_with_input!(env, command, input, chdir: nil)
  location = chdir ? " (cwd: #{chdir})" : ""
  puts "$ #{Shellwords.join(command)}#{location}"

  stdout, stderr, status =
    if chdir
      Open3.capture3(env, *command, chdir: chdir, stdin_data: input)
    else
      Open3.capture3(env, *command, stdin_data: input)
    end

  return if status.success?

  raise <<~MSG.strip
    Command failed with exit status #{status.exitstatus}: #{Shellwords.join(command)}
    stdout:
    #{stdout}
    stderr:
    #{stderr}
  MSG
end

def configure_opsd_provider!(env, opsd_bin, provider)
  profile_input = "#{provider}\n\nfra1\n"

  begin
    run_with_input!(env, [*opsd_bin, "config", "profile", "create", provider], profile_input)
    run!(env, [*opsd_bin, "config", "profile", "use", provider])
  rescue RuntimeError
    run!(env, [*opsd_bin, "config", "set", "provider", provider])
  end
end

def primary_workload_port(manifest_path)
  data = YAML.load_file(manifest_path)
  compute_group = Array(data.dig("spec", "compute_groups")).first
  return nil unless compute_group.is_a?(Hash)

  compute_group["port"]
end

def apply_growth_mutation!(entry, env, opsd_bin, manifest_path)
  mutation = entry.fetch("mutation")

  case mutation
  when "add-public-cdn-endpoint"
    run!(env, [*opsd_bin, "add", "cdn-endpoint", manifest_path.to_s, "--origin", "assets-main", "--id", "assets-cdn"])
  when "add-bastion-node"
    target_profile = entry.fetch("target_profile", "s-1vcpu-1gb")
    run!(env, [*opsd_bin, "add", "node", "vm", manifest_path.to_s, "--id", "bastion", "--role", "bastion", "--profile", target_profile])
  when "remove-cdn-endpoint"
    run!(env, [*opsd_bin, "remove", "cdn-endpoint", manifest_path.to_s, "cdn-public"])
  when "add-cache-redis"
    run!(env, [*opsd_bin, "add", "cache", "redis", manifest_path.to_s])
  when "remove-cache"
    run!(env, [*opsd_bin, "remove", "cache", manifest_path.to_s, "cache-main"])
  when "resize-cache"
    target_profile = entry.fetch("target_profile")
    run!(env, [*opsd_bin, "resize", "cache", manifest_path.to_s, "cache-main", "--profile", target_profile])
  when "resize-compute-group"
    target_profile = entry.fetch("target_profile")
    run!(env, [*opsd_bin, "resize", "compute-group", manifest_path.to_s, "primary", "--profile", target_profile])
  when "scale-compute-group"
    target_replicas = entry.fetch("target_replicas")
    run!(env, [*opsd_bin, "scale", "compute-group", manifest_path.to_s, "primary", "--replicas", target_replicas.to_s])
  when "add-public-load-balancer-and-scale"
    target_port = primary_workload_port(manifest_path) || 80
    run!(env, [*opsd_bin, "add", "load-balancer", manifest_path.to_s, "--id", "web-public", "--visibility", "public", "--port", "80", "--target-port", target_port.to_s])
    run!(env, [*opsd_bin, "attach", "compute-group", manifest_path.to_s, "primary", "--to", "web-public"])
    run!(env, [*opsd_bin, "scale", "compute-group", manifest_path.to_s, "primary", "--replicas", "3"])
  when "remove-public-load-balancer"
    target_port = primary_workload_port(manifest_path) || 80
    run!(env, [*opsd_bin, "add", "load-balancer", manifest_path.to_s, "--id", "web-public", "--visibility", "public", "--port", "80", "--target-port", target_port.to_s])
    run!(env, [*opsd_bin, "attach", "compute-group", manifest_path.to_s, "primary", "--to", "web-public"])
    run!(env, [*opsd_bin, "remove", "load-balancer", manifest_path.to_s, "web-public"])
  when "detach-public-load-balancer"
    target_port = primary_workload_port(manifest_path) || 80
    run!(env, [*opsd_bin, "add", "load-balancer", manifest_path.to_s, "--id", "web-public", "--visibility", "public", "--port", "80", "--target-port", target_port.to_s])
    run!(env, [*opsd_bin, "attach", "compute-group", manifest_path.to_s, "primary", "--to", "web-public"])
    run!(env, [*opsd_bin, "detach", "compute-group", manifest_path.to_s, "primary", "--from", "web-public"])
  when "resize-database"
    target_profile = entry.fetch("target_profile")
    run!(env, [*opsd_bin, "resize", "database", manifest_path.to_s, "db-main", "--profile", target_profile])
  else
    raise "Unsupported smoke mutation: #{mutation}"
  end
end

matrix_path = ENV["OPSD_SMOKE_MATRIX_FILE"] ? Pathname(ENV.fetch("OPSD_SMOKE_MATRIX_FILE")).expand_path : nil
direct_provider = ENV["OPSD_SMOKE_PROVIDER"]
direct_blueprint = ENV["OPSD_SMOKE_BLUEPRINT"]
direct_variant = ENV["OPSD_SMOKE_VARIANT"]
direct_mutation = ENV["OPSD_SMOKE_MUTATION"]
direct_target_profile = ENV["OPSD_SMOKE_TARGET_PROFILE"]
direct_target_replicas = ENV["OPSD_SMOKE_TARGET_REPLICAS"]

if direct_provider && direct_blueprint && direct_variant
  provider = direct_provider
  cases = [{
    "blueprint" => direct_blueprint,
    "variant" => direct_variant,
    "mode" => direct_mutation ? "growth" : "baseline",
    "mutation" => direct_mutation,
    "target_profile" => direct_target_profile,
    "target_replicas" => direct_target_replicas
  }]
  batch_size = 1
  batch_index = 0
  case_index = "0"
  matrix = nil
elsif matrix_path
  matrix = YAML.load_file(matrix_path)
  provider = matrix.fetch("provider")
  cases = Array(matrix.fetch("cases"))
  batch_size = Integer(ENV.fetch("OPSD_SMOKE_BATCH_SIZE", cases.length.to_s))
  batch_index = Integer(ENV.fetch("OPSD_SMOKE_BATCH_INDEX", "0"))
  case_index = ENV["OPSD_SMOKE_CASE_INDEX"]
else
  provider = ENV.fetch("OPSD_SMOKE_PROVIDER_DEFAULT", "digitalocean")
  catalog = OPSd::ModuleCatalog.new(workspace_root: repo_root, env: ENV)
  resolution = catalog.resolve(provider)
  template_store = OPSd::TemplateStore.new(app_root: repo_root, workspace_root: resolution.fetch(:workspace_root))

  cases = template_store.blueprint_entries(provider: provider).flat_map do |entry|
    Array(entry[:variants]).filter_map do |variant|
      variant_id = variant.is_a?(Hash) ? variant["id"] : variant
      next nil if variant_id.nil? || variant_id.to_s.empty?

      { "blueprint" => entry.fetch(:id), "variant" => variant_id }
    end
  end

  matrix = nil
  batch_size = Integer(ENV.fetch("OPSD_SMOKE_BATCH_SIZE", cases.length.to_s))
  batch_index = Integer(ENV.fetch("OPSD_SMOKE_BATCH_INDEX", "0"))
  case_index = ENV["OPSD_SMOKE_CASE_INDEX"]
end

workspace_root =
  if ENV["OPSD_WORKSPACE_ROOT"]
    Pathname(ENV.fetch("OPSD_WORKSPACE_ROOT")).expand_path
  elsif repo_root.join("modules").directory?
    repo_root
  elsif repo_root.join("..", "modules").directory?
    repo_root.join("..").realpath
  else
    raise "Set OPSD_WORKSPACE_ROOT to a directory containing modules/<provider>/*"
  end

tofu_bin = ENV.fetch("TOFU_BIN", "tofu")
work_root = Pathname(ENV.fetch("OPSD_SMOKE_WORKDIR", repo_root.join(".tmp/beta-blueprint-smoke").to_s))
opsd_bin = [
  ENV.fetch("RUBY", RbConfig.ruby),
  "-I#{repo_root.join('lib')}",
  "-ropsd/cli",
  "-e",
  "OPSd::CLI.run(ARGV)",
  "--"
]

if batch_size <= 0
  raise "OPSD_SMOKE_BATCH_SIZE must be greater than zero"
end

if batch_index.negative?
  raise "OPSD_SMOKE_BATCH_INDEX must be zero or greater"
end

if !case_index.nil? && !(case_index =~ /\A\d+\z/)
  raise "OPSD_SMOKE_CASE_INDEX must be a non-negative integer"
end

unless workspace_root.join("modules", provider).directory?
  raise "Workspace root #{workspace_root} does not contain modules/#{provider}"
end

FileUtils.rm_rf(work_root)
FileUtils.mkdir_p(work_root)

selected_cases =
  if case_index
    index = Integer(case_index)
    entry = cases[index]
    raise "No smoke case at index #{index}" if entry.nil?

    [[index, entry]]
  else
    batch_offset = batch_index * batch_size
    entries = cases.slice(batch_offset, batch_size) || []
    entries.each_with_index.map { |entry, local_index| [batch_offset + local_index, entry] }
  end

puts "Smoke provider: #{provider}"
puts "Workspace root: #{workspace_root}"
puts "Matrix file: #{matrix_path}" if matrix
puts "Cases total: #{cases.length}"
puts "Batch size: #{batch_size}"
puts "Batch index: #{batch_index}"
puts "Cases in batch: #{selected_cases.length}"
puts "Case index: #{case_index}" unless case_index.nil?

if selected_cases.empty?
  puts
  puts "No smoke cases selected for this batch."
  exit 0
end

selected_cases.each do |index, entry|
  blueprint = entry.fetch("blueprint")
  variant = entry.fetch("variant")
  mutation = entry["mutation"].to_s
  slug_parts = [provider, blueprint, variant]
  slug_parts << mutation unless mutation.empty?
  slug = slug_parts.join("-").gsub(/[^a-zA-Z0-9._-]+/, "-")

  case_root = work_root.join(format("%02d-%s", index + 1, slug))
  manifest_path = case_root.join("manifest.yaml")
  rendered_path = case_root.join("rendered")

  FileUtils.rm_rf(case_root)
  FileUtils.mkdir_p(case_root)

  env = {
    "OPSD_APP_ROOT" => repo_root.to_s,
    "OPSD_WORKSPACE_ROOT" => workspace_root.to_s
  }

  puts
  puts "==> [#{index + 1}/#{cases.length}] #{blueprint}:#{variant}"
  puts "    mutation: #{mutation}" unless mutation.empty?
  puts "    workdir: #{case_root}"

  configure_opsd_provider!(env, opsd_bin, provider)
  run!(env, [*opsd_bin, "init", "blueprint", blueprint, manifest_path.to_s, "--variant", variant])
  apply_growth_mutation!(entry, env, opsd_bin, manifest_path) unless mutation.empty?
  run!(env, [*opsd_bin, "validate", "manifest", manifest_path.to_s])
  run!(env, [*opsd_bin, "render", "manifest", manifest_path.to_s, "--output", rendered_path.to_s])
  run!(env, [tofu_bin, "init", "-backend=false", "-input=false"], chdir: rendered_path.to_s)
  run!(env, [tofu_bin, "validate"], chdir: rendered_path.to_s)
end

puts
if case_index
  puts "Smoke flow completed for case #{case_index}."
else
  puts "Smoke flow completed for #{selected_cases.length} beta blueprint variants in batch #{batch_index}."
end
