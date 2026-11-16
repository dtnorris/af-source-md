# frozen_string_literal: true

require "pathname"

module AFSourceMD
  # Explicit human-readable source identity checks, independent of caller errors.
  module SourceIdentity
    module_function

    SOURCE_FILE_EXTENSION = /\.(?:md|pdf)\z/i
    RELATIVE_PATH_PREFIX = /\A(?:~|\.{1,2})[\\\/]/
    WINDOWS_ABSOLUTE_PATH = /\A(?:[A-Za-z]:[\\\/]|\\\\)/

    # Validate a declared identity using the supplied error class; return its trimmed text or raise that error.
    def validate!(value, error_class:)
      source_id = value.to_s.strip
      if source_id.empty?
        raise error_class,
              "--source-id must be a non-empty human-readable canonical source identity"
      end
      return source_id unless path_like?(source_id)

      raise error_class,
            "--source-id must be a human-readable canonical source identity, " \
            "not a filesystem path or source filename: #{source_id.inspect}"
    end

    # Return whether the supplied identity resembles a filesystem path or source filename.
    def path_like?(value)
      source_id = value.to_s.strip
      return true if Pathname.new(source_id).absolute?
      return true if RELATIVE_PATH_PREFIX.match?(source_id)
      return true if WINDOWS_ABSOLUTE_PATH.match?(source_id)
      return true if SOURCE_FILE_EXTENSION.match?(source_id)

      false
    end
  end
end
