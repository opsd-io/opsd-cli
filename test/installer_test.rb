# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "digest"
require "socket"

class InstallerTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/install.sh", __dir__)

  def setup
    @root = Dir.mktmpdir("opsd installer ")
    @prefix = File.join(@root, "installed ' bundles")
    @shell_config = File.join(@root, "shell configuration")
    os = RUBY_PLATFORM.include?("darwin") ? "darwin" : "linux"
    arch = `uname -m`.strip.match?(/arm64|aarch64/) ? "arm64" : "amd64"
    @name = "opsd_0.1.0_#{os}_#{arch}"
    bundle = File.join(@root, @name)
    %w[bin runtime/bin].each { |path| FileUtils.mkdir_p(File.join(bundle, path)) }
    %w[bin/opsd bin/opsd-mcp runtime/bin/ruby].each do |path|
      file = File.join(bundle, path)
      File.write(file, <<~SH)
        #!/bin/sh
        if [ "${1:-}" = completion ]; then
          printf '_opsd() { :; }\\n'
        else
          printf '0.1.0\\n'
        fi
      SH
      FileUtils.chmod(0o755, file)
    end
    @archive = File.join(@root, "#{@name}.tar.gz")
    _, stderr, status = Open3.capture3("tar", "-czf", @archive, "-C", @root, @name)
    assert status.success?, stderr
  end

  def teardown
    @server_thread&.kill
    @server_thread&.join
    @server&.close
    FileUtils.remove_entry(@root)
  end

  def install(*arguments, input: "", env: {}, shell_setup: false)
    options = shell_setup ? ["--shell-config-dir", @shell_config] : ["--no-shell-setup"]
    Open3.capture3(env, "sh", SCRIPT, "--prefix", @prefix, *options, *arguments, stdin_data: input)
  end

  def test_local_install_handles_spaces_quotes_and_preserves_previous_installation
    2.times do
      stdout, stderr, status = install("--archive", @archive)
      assert status.success?, stderr
      # Execute the printed export exactly as a user would paste it.
      export = stdout.lines.find { |line| line.start_with?("export OPSD_APP_ROOT=") }
      output, error, exported = Open3.capture3("sh", "-c", "#{export}\"$OPSD_APP_ROOT/bin/opsd\" version")
      assert exported.success?, error
      assert_equal "0.1.0\n", output
    end
    assert_equal 2, Dir.glob(File.join(@prefix, "install.*", @name)).size
  end

  def test_local_prompt_and_missing_archive
    stdout, stderr, status = install("--local", input: "#{@archive}\n")
    assert status.success?, stderr
    assert_includes stdout, "Installed OPSd 0.1.0"
    _, stderr, status = install("--archive", File.join(@root, "missing.tar.gz"))
    refute status.success?
    assert_includes stderr, "Archive not found"
    assert_equal 1, Dir.glob(File.join(@prefix, "install.*")).size
  end

  def test_empty_local_selection_does_not_download_or_install
    _, stderr, status = install("--local", input: "\n")
    refute status.success?
    assert_includes stderr, "No archive path provided"
    refute File.exist?(@prefix)
  end

  def test_invalid_archive_does_not_create_installation_directory
    File.write(@archive, "not a gzip archive")
    _, _, status = install("--archive", @archive)
    refute status.success?
    refute File.exist?(@prefix)
  end

  def test_incomplete_bundle_does_not_create_installation_directory
    FileUtils.rm(File.join(@root, @name, "runtime/bin/ruby"))
    system("tar", "-czf", @archive, "-C", @root, @name, exception: true)
    _, stderr, status = install("--archive", @archive)
    refute status.success?
    assert_includes stderr, "Incomplete bundle"
    refute File.exist?(@prefix)
  end

  def test_downloads_latest_release_and_checks_checksum
    env = release_server
    stdout, stderr, status = install(env: env)
    assert status.success?, stderr
    assert_includes stdout, "Installed OPSd 0.1.0"
    assert_includes @requests, "/latest"
    assert_includes @requests, "/download/v0.1.0/#{@name}.tar.gz.sha256"
  end

  def test_checksum_mismatch_preserves_existing_files
    FileUtils.mkdir_p(@prefix)
    File.write(File.join(@prefix, "keep"), "existing installation")
    _, stderr, status = install("--version", "v0.1.0", env: release_server(checksum: "0" * 64))
    refute status.success?
    assert_includes stderr, "checksum mismatch"
    assert_equal ["keep"], Dir.children(@prefix)
    assert_equal "existing installation", File.read(File.join(@prefix, "keep"))
  end

  def test_missing_release_asset_fails_without_installing
    _, stderr, status = install("--version", "9.9.9", env: release_server)
    refute status.success?
    assert_includes stderr, "Release asset unavailable"
    refute File.exist?(@prefix)
  end

  def test_bash_setup_preserves_existing_config_and_activates_path_and_completion
    FileUtils.mkdir_p(@shell_config)
    File.write(File.join(@shell_config, ".bashrc"), "# existing shell configuration\n")
    File.write(File.join(@shell_config, ".profile"), "# existing login configuration\n")
    installed_root = nil
    2.times do
      output, stderr, status = install("--archive", @archive, "--shell", "bash", shell_setup: true)
      assert status.success?, stderr
      installed_root = output[/^Installed OPSd \S+ in (.+)$/, 1]
    end
    rc = File.read(File.join(@shell_config, ".bashrc"))
    assert_includes rc, "# existing shell configuration"
    assert_equal 1, rc.scan("# OPSd installer: PATH and completion").size
    refute File.exist?(File.join(@shell_config, ".bash_profile"))
    assert_includes File.read(File.join(@shell_config, ".profile")), "# existing login configuration"
    stdout, stderr, status = Open3.capture3("bash", "--noprofile", "--norc", "-c",
                                           'source "$1"; command -v opsd; type -t _opsd; opsd version',
                                           "installer-test", File.join(@shell_config, ".bashrc"))
    assert status.success?, stderr
    assert_includes stdout, "#{installed_root}/bin/opsd"
    assert_includes stdout, "function\n0.1.0"
  end

  def test_detects_zsh_and_uses_config_directory_override
    _, stderr, status = install("--archive", @archive, shell_setup: true, env: { "SHELL" => "/bin/zsh" })
    assert status.success?, stderr
    assert File.file?(File.join(@shell_config, ".zshrc"))
    init = File.read(File.join(@prefix, "shell/zsh/init.sh"))
    assert_includes init, "autoload -Uz compinit"
    assert_includes init, "export OPSD_APP_ROOT="
  end

  def test_fish_setup_uses_conf_d_and_fish_environment_syntax
    _, stderr, status = install("--archive", @archive, "--shell", "fish", shell_setup: true)
    assert status.success?, stderr
    assert File.file?(File.join(@shell_config, "conf.d/opsd.fish"))
    init = File.read(File.join(@prefix, "shell/fish/init.sh"))
    assert_includes init, "set -gx OPSD_APP_ROOT"
    assert_includes init, "set -gx PATH"
    assert_includes init, "installed \\' bundles"
  end

  def test_unsupported_shell_fails_before_creating_files
    _, stderr, status = install("--archive", @archive, "--shell", "unknown", shell_setup: true)
    refute status.success?
    assert_includes stderr, "Select --shell"
    refute File.exist?(@prefix)
    refute File.exist?(@shell_config)
  end

  def test_no_shell_setup_leaves_shell_configuration_untouched
    _, stderr, status = install("--archive", @archive)
    assert status.success?, stderr
    refute File.exist?(@shell_config)
    refute File.exist?(File.join(@prefix, "shell"))
  end

  private

  # Serve actual tar bytes and redirects over loopback; exercise real curl and SHA tools.
  def release_server(checksum: Digest::SHA256.file(@archive).hexdigest)
    @requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    base = "http://127.0.0.1:#{@server.addr[1]}"
    @server_thread = Thread.new do
      loop do
        socket = @server.accept
        begin
          path = socket.gets.split[1]
          @requests << path
          while (line = socket.gets) && line != "\r\n"; end
          headers = ""
          code, body = case path
                       when "/latest"
                         headers = "Location: #{base}/tag/v0.1.0\r\n"
                         [302, ""]
                       when "/tag/v0.1.0" then [200, "release"]
                       when "/download/v0.1.0/#{@name}.tar.gz" then [200, File.binread(@archive)]
                       when "/download/v0.1.0/#{@name}.tar.gz.sha256" then [200, "#{checksum}  #{@name}.tar.gz\n"]
                       else [404, "missing"]
                       end
          socket.write("HTTP/1.1 #{code} Response\r\n#{headers}Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
          socket.write(body)
        ensure
          socket.close
        end
      end
    end
    { "OPSD_RELEASE_BASE_URL" => base, "NO_PROXY" => "127.0.0.1", "no_proxy" => "127.0.0.1" }
  end
end
