# frozen_string_literal: true

module AFSourceMD
  # Pipeline source representation checks; no artifact or editorial dependencies.
  module Registry
    SOURCE_REGISTRY_SCHEMA_VERSION = "adventurefinder-source-registry/v0.1"
    SHA256_RE = /\A[0-9a-f]{64}\z/

    module_function

    # Require complete containment of pages in one segment; return nil or raise ValidationError.
    def validate_registry_range!(entry, pages, label)
      segments = entry[:segments]
      return unless segments

      matches = segments.select do |segment|
        pages.fetch(:start) >= segment.fetch(:start_page) && pages.fetch(:end) <= segment.fetch(:end_page)
      end
      if matches.empty?
        raise ValidationError,
              "#{label}.printed_pages #{pages.fetch(:start)}-#{pages.fetch(:end)} are not fully contained by a registered source segment"
      end
      if matches.length > 1
        raise ValidationError,
              "#{label}.printed_pages #{pages.fetch(:start)}-#{pages.fetch(:end)} match multiple registered source segments"
      end
    end

    # Load the selected v0.1 registry beneath root; return its envelope and paths or raise ValidationError.
    def registry_context(root, registry_path)
      path = if registry_path
               candidate = Pathname.new(registry_path)
               candidate.absolute? ? File.expand_path(registry_path) : File.expand_path(registry_path, root)
             else
               File.join(root, "source_registry.yml")
             end
      path = existing_file!(path, "source registry")
      relative = relative_under_root!(root, path, "source registry")
      raw = load_yaml_mapping(path, "source registry")
      exact_keys!(raw, %w[schema_version sources], "source registry")
      require_keys!(raw, %w[schema_version sources], "source registry")
      unless raw["schema_version"] == SOURCE_REGISTRY_SCHEMA_VERSION
        raise ValidationError,
              "Unsupported source registry schema #{raw['schema_version'].inspect}; expected #{SOURCE_REGISTRY_SCHEMA_VERSION.inspect}"
      end
      mapping!(raw["sources"], "source registry sources")
      raw["sources"].each_key do |key|
        nonblank_string!(key, "source registry source key")
      end
      raw.merge("path" => path, "relative_path" => relative)
    end

    # Validate a pipeline mapping; return files/segments with ordered nonoverlap checks or raise ValidationError.
    def normalize_registry_entry(source_id, entry)
      mapping!(entry, "source registry entry #{source_id.inspect}")
      if entry.key?("segments")
        exact_keys!(entry, %w[segments], "source registry entry #{source_id.inspect}")
        segments = entry["segments"]
        unless segments.is_a?(Array) && !segments.empty?
          raise ValidationError, "Source registry entry #{source_id.inspect} segments must be a non-empty list"
        end
        normalized = segments.map.with_index do |segment, index|
          label = "source registry entry #{source_id.inspect} segment #{index + 1}"
          mapping!(segment, label)
          exact_keys!(segment, %w[start_page end_page file page_marker_offset], label)
          require_keys!(segment, %w[start_page end_page file], label)
          start_page = positive_integer!(segment["start_page"], "#{label}.start_page")
          end_page = positive_integer!(segment["end_page"], "#{label}.end_page")
          raise ValidationError, "#{label}.start_page exceeds end_page" if start_page > end_page
          validate_offset!(segment["page_marker_offset"], label) if segment.key?("page_marker_offset")
          {
            start_page: start_page,
            end_page: end_page,
            file: relative_filename!(segment["file"], "#{label}.file")
          }
        end
        normalized.each_cons(2) do |left, right|
          if left[:start_page] >= right[:start_page]
            raise ValidationError, "Source registry entry #{source_id.inspect} segments must be ordered by start_page"
          end
        end
        normalized.combination(2) do |left, right|
          if left[:start_page] <= right[:end_page] && right[:start_page] <= left[:end_page]
            raise ValidationError, "Source registry entry #{source_id.inspect} contains overlapping segments"
          end
        end
        { files: normalized.map { |segment| segment.fetch(:file) }.uniq, segments: normalized }
      else
        exact_keys!(entry, %w[file page_marker_offset], "source registry entry #{source_id.inspect}")
        require_keys!(entry, %w[file], "source registry entry #{source_id.inspect}")
        validate_offset!(entry["page_marker_offset"], "source registry entry #{source_id.inspect}") if entry.key?("page_marker_offset")
        { files: [relative_filename!(entry["file"], "source registry entry #{source_id.inspect}.file")], segments: nil }
      end
    end

    # Validate the supplied explicitly signed offset; return nil or raise ValidationError.
    def validate_offset!(value, label)
      unless value.is_a?(String) && /\A[+-]\d+\z/.match?(value)
        raise ValidationError, "#{label}.page_marker_offset must be an explicitly signed integer string"
      end
    end

    # Resolve a relative source beneath root; return its existing path or raise ValidationError.
    def source_file!(root, filename)
      relative = relative_filename!(filename, "Markdown filename")
      path = File.expand_path(relative, root)
      relative_under_root!(root, path, "Markdown source")
      existing_file!(path, "Markdown source")
    end

    # Require a nonblank relative filename; return the original string or raise ValidationError.
    def relative_filename!(value, label)
      value = nonblank_string!(value, label)
      path = Pathname.new(value)
      raise ValidationError, "#{label} must be relative to the source root" if path.absolute?
      value
    end

    # Return the lexical relative path beneath root or raise ValidationError; symlinks retain existing behavior.
    def relative_under_root!(root, path, label)
      root_path = Pathname.new(File.expand_path(root))
      target = Pathname.new(File.expand_path(path))
      relative = target.relative_path_from(root_path).to_s
      if relative == ".." || relative.start_with?("..#{File::SEPARATOR}")
        raise ValidationError, "#{label} must live beneath source root #{root_path}"
      end
      relative
    rescue ArgumentError
      raise ValidationError, "#{label} must live beneath source root #{root_path}"
    end

    # Expand an existing source directory; return its path or raise ValidationError.
    def expanded_source_root(path)
      raise ValidationError, "Source root is required" if path.nil? || path.to_s.strip.empty?
      root = File.expand_path(path)
      raise ValidationError, "Source root does not exist: #{root}" unless Dir.exist?(root)
      root
    end

    # Expand a required existing file; return its path or raise ValidationError.
    def existing_file!(path, label)
      raise ValidationError, "#{label} path is required" if path.nil? || path.to_s.strip.empty?
      expanded = File.expand_path(path)
      raise ValidationError, "Missing #{label}: #{expanded}" unless File.file?(expanded)
      expanded
    end

    # Read a mapping with Date/Time and aliases disabled; return it or raise ValidationError.
    def load_yaml_mapping(path, label)
      raw = YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: false) || {}
      mapping!(raw, label)
      raw
    rescue Psych::Exception => e
      raise ValidationError, "Invalid YAML in #{label} #{path}: #{e.message}"
    end

    # Require a Hash value; return it or raise ValidationError using the supplied label.
    def mapping!(value, label)
      raise ValidationError, "#{label} must be a mapping" unless value.is_a?(Hash)
      value
    end

    # Reject unknown mapping keys with ValidationError; otherwise return nil.
    def exact_keys!(hash, allowed, label)
      unknown = hash.keys.map(&:to_s) - allowed
      raise ValidationError, "#{label} has unknown fields: #{unknown.join(', ')}" unless unknown.empty?
    end

    # Reject absent required mapping keys with ValidationError; otherwise return nil.
    def require_keys!(hash, required, label)
      missing = required.reject { |key| hash.key?(key) }
      raise ValidationError, "#{label} is missing required fields: #{missing.join(', ')}" unless missing.empty?
    end

    # Require nonblank String input; return its original bytes or raise ValidationError.
    def nonblank_string!(value, label)
      unless value.is_a?(String) && !value.strip.empty?
        raise ValidationError, "#{label} must be a nonblank string"
      end
      value
    end

    # Require a positive Integer; return it or raise ValidationError.
    def positive_integer!(value, label)
      raise ValidationError, "#{label} must be a positive integer" unless value.is_a?(Integer) && value.positive?
      value
    end

    # Require the declared lowercase SHA-256 to match file bytes; return nil or raise ValidationError.
    def verify_sha!(declared, path, label)
      unless declared.is_a?(String) && SHA256_RE.match?(declared)
        raise ValidationError, "#{label} sha256 must be 64 lowercase hexadecimal characters"
      end
      actual = sha256(path)
      raise ValidationError, "#{label} sha256 mismatch: freeze=#{declared} actual=#{actual}" unless declared == actual
    end

    # Return the file SHA-256 hex digest; ordinary filesystem errors propagate.
    def sha256(path)
      Digest::SHA256.file(path).hexdigest
    end
  end
end
