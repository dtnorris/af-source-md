# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/af_source_md"

# Standalone mechanical conformance; no pipeline/scorer classes or helpers load.
class MechanicsTest < Minitest::Test
  ORACLE = "<!-- Printed Page 1 -->\nα\n<!-- Printed Page 2 -->\nΩ\n"
  Request = Struct.new(:source_book, :start_page, :end_page)

  # Verify first/second append, prior bytes/mode, duplicate refusal and the exact
  # registered UTF-8 slice using real owner validation, resolution and extraction.
  def test_registration_to_exact_raw_read_without_callers
    Dir.mktmpdir("source-md-") do |root|
      registry = File.join(root, "source_registry.yml")
      first = File.join(root, "first.md")
      second = File.join(root, "second.md")
      File.binwrite(registry, "# keep\nschema_version: adventurefinder-source-registry/v0.1\nsources: {} # keep\n")
      File.chmod(0o640, registry)
      File.binwrite(first, ORACLE)
      File.binwrite(second, "<!-- PAGE: 1 -->\n1\n")
      first_result = AFSourceMD::SourceRegister.register!(source_root: root, source_id: "Mechanical Source", markdown_path: first)
      prior = File.binread(registry)
      AFSourceMD::SourceRegister.register!(source_root: root, source_id: "Second Source", markdown_path: second)
      assert File.binread(registry).start_with?(prior)
      assert_equal Digest::SHA256.hexdigest(prior), first_result.registry_sha256_after
      assert_equal 0o640, File.stat(registry).mode & 0o777
      assert_includes File.binread(registry), "# keep"
      accepted = File.binread(registry)
      assert_raises(AFSourceMD::ValidationError) do
        AFSourceMD::SourceRegister.register!(source_root: root, source_id: "Mechanical Source", markdown_path: second)
      end
      assert_equal accepted, File.binread(registry)
      resolution = AFSourceMD::SourceResolver.new(source_root: root, registry_path: registry).resolve(Request.new("Mechanical Source", 1, 2))
      assert_equal "explicit_mapping", resolution.strategy
      extraction = AFSourceMD::SourceDocument.new(resolution.path).extract(start_page: 1, end_page: 2)
      assert_equal ORACLE, extraction.text
      assert_equal 54, extraction.text.bytesize
      assert_equal "b71d7a597ee169616c05015d7836d7252fc87d6ca1bb24df92009bc8c0bc979f", Digest::SHA256.hexdigest(extraction.text)
      assert extraction.text.valid_encoding?
      assert_empty Dir.glob(File.join(root, ".source-registry-*"))
      refute defined?(AfDataPipeline)
      refute defined?(AFScoring)
    end
  end

  # Preserve strict pipeline offset/range policy alongside lazy reader policy;
  # no normalization may silently strengthen an existing scorer read.
  def test_strict_pipeline_and_lazy_reader_policies_remain_distinct
    Dir.mktmpdir("source-md-policy-") do |root|
      File.write(File.join(root, "first.md"), ORACLE)
      registry = File.join(root, "source_registry.yml")
      File.write(registry, YAML.dump({"schema_version" => AFSourceMD::Registry::SOURCE_REGISTRY_SCHEMA_VERSION,
        "sources" => {"Mechanical Source" => {"file" => "first.md", "page_marker_offset" => false}, "Unselected" => 0}}))
      selected = AFSourceMD::SourceResolver.new(source_root: root, registry_path: registry).resolve(Request.new("Mechanical Source", 1, 2))
      assert_equal 0, selected.page_marker_offset
      assert_raises(AFSourceMD::ValidationError) do
        AFSourceMD::Registry.normalize_registry_entry("Mechanical Source", {"file" => "first.md", "page_marker_offset" => false})
      end
      assert_raises(AFSourceMD::ConfigurationError) do
        AFSourceMD::SourceResolver.new(source_root: root, registry_path: registry).resolve(Request.new("Unselected", 1, 2))
      end
    end
  end
end
