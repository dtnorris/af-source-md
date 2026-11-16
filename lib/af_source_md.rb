# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "tempfile"
require "time"
require "yaml"

# Standalone source representation mechanics; requires Ruby 3.2 or newer.
module AFSourceMD
  VERSION = "0.1.0"
  API_VERSION = "af-source-md/v0.1"
  ROOT = File.realpath("..", __dir__)

  # Base error for mechanical source validation and reading.
  class Error < StandardError; end
  # Invalid registry, source identity, path, hash or registration candidate.
  class ValidationError < Error; end
  # Invalid selected source registry or mapping configuration.
  class ConfigurationError < Error; end
  # A source or required source file could not be resolved.
  class SourceResolutionError < Error; end
  # More than one candidate or segment matched the requested source.
  class AmbiguousSourceError < SourceResolutionError; end
  # Requested raw page boundaries could not be satisfied under caller options.
  class SourceBoundaryError < Error; end
end

require_relative "af_source_md/source_identity"
require_relative "af_source_md/registry"
require_relative "af_source_md/source_register"
require_relative "af_source_md/source_resolver"
require_relative "af_source_md/source_document"
