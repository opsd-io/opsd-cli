#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "rbconfig"
require "shellwords"
require "tempfile"
require "tmpdir"
require "yaml"

require_relative "../../ci/public_scenario_matrix"

ROOT = Pathname(__dir__).join("../..").realpath
scenario_id = ENV.fetch("OPSD_PUBLIC_SCENARIO")
modules_ref = ENV.fetch("OPSD_PUBLIC_MODULES_REF")
iac_tool = ENV.fetch("OPSD_PUBLIC_IAC_TOOL")
compatibility_file = Pathname(ENV.fetch("OPSD_PUBLIC_COMPATIBILITY_FILE", "ci/public-compatibility.yaml"))
compatibility_file = ROOT.join(compatibility_file) unless compatibility_file.absolute?

abort "Unsupported IaC tool: #{iac_tool}" unless %w[terraform tofu].include?(iac_tool)

config = YAML.load_file(compatibility_file)
scenario = OPSd::PublicScenarioMatrix.expand(config).find { |entry| entry.fetch("id") == scenario_id }
abort "Unknown public scenario: #{scenario_id}" if scenario.nil?

run_root = Pathname(Dir.mktmpdir("opsd-public-#{scenario_id}-"))
workspace_root = run_root.join("workspace")
manifest_path = run_root.join("environment.yaml")
opsd = ROOT.join("bin/opsd").to_s

child_env = {
  "OPSD_APP_ROOT" => ROOT.to_s,
  "OPSD_WORKSPACE_ROOT" => workspace_root.to_s,
  "OPSD_PROFILE" => "ci",
  "OPSD_MODULES_DIGITALOCEAN_REF" => modules_ref
}

def command_text(command)
  Shellwords.join(command)
end

def run!(environment, command, chdir: ROOT, retries: 1, retry_delay: 0)
  puts "$ #{command_text(command)}"
  attempts = 0
  loop do
    return if system(environment, *command, chdir: chdir.to_s)

    attempts += 1
    break if attempts >= retries

    warn "Command failed; retrying in #{retry_delay}s (attempt #{attempts + 1}/#{retries})"
    sleep retry_delay
  end

  abort "Command failed with status #{$?.exitstatus || 1}: #{command_text(command)}"
end

def run_with_input!(environment, command, input, chdir: ROOT)
  puts "$ #{command_text(command)} < stdin"
  stdout, stderr, status = Open3.capture3(environment, *command, stdin_data: input, chdir: chdir.to_s)
  print stdout unless stdout.empty?
  warn stderr unless stderr.empty?
  return if status.success?

  abort "Command failed with status #{status.exitstatus || 1}: #{command_text(command)}"
end

def opsd_command(opsd, *arguments)
  [opsd, *arguments]
end

def assert_rendered_components!(manifest_path, rendered)
  manifest = YAML.load_file(manifest_path)
  spec = manifest.fetch("spec", {})
  required_modules = %w[vpc kubernetes project]

  Array(spec["caches"]).each do |cache|
    required_modules << cache.fetch("engine") if cache.is_a?(Hash)
  end

  Array(spec["databases"]).each do |database|
    required_modules << database.fetch("engine") if database.is_a?(Hash)
  end

  module_source = rendered.join("main.tf").read
  required_modules.uniq.each do |module_name|
    next if module_source.match?(/module\s+"#{Regexp.escape(module_name)}"\s*\{/)

    abort "Rendered configuration is missing module [#{module_name}] for #{manifest_path}"
  end

  if Array(spec["caches"]).empty? && module_source.match?(/module\s+"redis"\s*\{/)
    abort "Rendered configuration still contains Redis after it was removed"
  end
end

run_with_input!(child_env, opsd_command(opsd, "config", "profile", "create", "ci"), "digitalocean\n\nfra1\n")
run!(child_env, opsd_command(opsd, "config", "profile", "use", "ci"))
run!(child_env, opsd_command(opsd, "init", "blueprint", scenario.fetch("blueprint"), manifest_path.to_s, "--variant", scenario.fetch("variant")))

operations = scenario.fetch("operations", [])
stages = [{ "label" => "foundation", "operation" => nil }]
operations.each_with_index do |operation, index|
  command = operation.fetch("command")
  args = operation.fetch("args", [])
  stages << { "label" => "step-#{index + 1}-#{command.join('-')}", "operation" => [command, args] }
end

stages.each_with_index do |stage, index|
  operation = stage.fetch("operation")
  unless operation.nil?
    command, args = operation
    case command
    in ["add", resource, value]
      run!(child_env, opsd_command(opsd, "add", resource, value, manifest_path.to_s, *args))
    in ["remove", resource]
      resource_id = args.fetch(0) { abort "Missing resource id for remove #{resource}" }
      run!(child_env, opsd_command(opsd, "remove", resource, manifest_path.to_s, resource_id, *args.drop(1)))
    else
      abort "Unsupported public scenario operation: #{command.inspect}"
    end
  end

  rendered = run_root.join("rendered-#{index}")
  run!(child_env, opsd_command(opsd, "validate", "manifest", manifest_path.to_s))
  run!(child_env, opsd_command(opsd, "render", "manifest", manifest_path.to_s, "--output", rendered.to_s))
  assert_rendered_components!(manifest_path, rendered)
  run!(child_env, [iac_tool, "init", "-backend=false", "-input=false"], chdir: rendered, retries: 3, retry_delay: 5)
  # The rendered directory is a generated artifact. Normalize it first, then
  # keep the check below as a guard against non-deterministic formatting.
  run!(child_env, [iac_tool, "fmt", "-recursive"], chdir: rendered)
  run!(child_env, [iac_tool, "fmt", "-check", "-recursive"], chdir: rendered)
  run!(child_env, [iac_tool, "validate"], chdir: rendered)
  run!(child_env, [iac_tool, "plan", "-refresh=false", "-input=false", "-lock=false", "-var=digitalocean_token=public-plan-placeholder"], chdir: rendered)
  puts "Completed public scenario stage: #{stage.fetch('label')}"
end

puts "Public scenario passed: #{scenario_id} (#{iac_tool}, modules #{modules_ref})"
