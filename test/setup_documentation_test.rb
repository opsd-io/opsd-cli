# frozen_string_literal: true

require "minitest/autorun"

class SetupDocumentationTest < Minitest::Test
  def test_canonical_setup_page_covers_profile_and_workspace_configuration
    setup_doc = File.read(path("docs/getting-started/setup.md"))

    assert_includes setup_doc, "This page is the canonical setup path for configuring OPSd locally."
    assert_includes setup_doc, "bin/opsd config profile create work"
    assert_includes setup_doc, "bin/opsd config profile use work"
    assert_includes setup_doc, "bin/opsd config profile current"
    assert_includes setup_doc, "OPSD_WORKSPACE_ROOT=/path/to/workspace"
    assert_includes setup_doc, "The configuration flow is intentionally small and stable"
  end

  def test_main_entrypoints_link_to_the_canonical_setup_page
    assert_includes File.read(path("README.md")), "[Setup](./docs/getting-started/setup.md)"
    assert_includes File.read(path("docs/index.md")), "[Setup](./getting-started/setup.md)"
    assert_includes File.read(path("docs/getting-started/install.md")), "[Setup](./setup.md)"
    assert_includes File.read(path("docs/getting-started/development-setup.md")), "[Setup](./setup.md)"
    assert_includes File.read(path("docs/getting-started/quickstart.md")), "[Setup](./setup.md)"
  end

  private

  def path(relative_path)
    File.expand_path("../#{relative_path}", __dir__)
  end
end
