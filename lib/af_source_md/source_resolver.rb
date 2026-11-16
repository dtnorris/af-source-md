# frozen_string_literal: true

require "yaml"
require "pathname"

module AFSourceMD
  # Lazy source registry resolution with the established scorer read policy.
  class SourceResolver
    REGISTRY_SCHEMA_VERSION = "adventurefinder-source-registry/v0.1"

    Resolution = Struct.new(
      :path, :strategy, :warnings, :page_marker_offset, keyword_init: true
    )

    # Bind the supplied paths/options to this mechanical reader or writer; loading may raise owner errors.
    def initialize(source_root:, registry_path:)
      @source_root = File.expand_path(source_root)
      raise SourceResolutionError, "Source root does not exist: #{@source_root}" unless Dir.exist?(@source_root)
      @mappings = load_registry(registry_path)
    end

    # Resolve the supplied source_book/start_page/end_page reader; return Resolution or raise a source/configuration error.
    def resolve(adventure)
      explicit = @mappings[adventure.source_book]
      if explicit
        if segmented_mapping?(explicit)
          return resolve_segmented_mapping(explicit, adventure)
        end

        mapping = normalize_mapping(explicit, source_book: adventure.source_book)
        path = absolute_or_rooted(mapping.fetch(:file))
        if File.file?(path)
          return Resolution.new(
            path: path,
            strategy: "explicit_mapping",
            warnings: [],
            page_marker_offset: mapping.fetch(:page_marker_offset)
          )
        end
        raise SourceResolutionError, "Configured source mapping for #{adventure.source_book.inspect} does not exist: #{path}"
      end

      candidates = markdown_files.select do |path|
        source_key = normalize_source(adventure.source_book)
        file_key = normalize_filename(File.basename(path, File.extname(path)))
        file_key == source_key || file_key.include?(source_key) || source_key.include?(file_key)
      end

      case candidates.length
      when 1
        Resolution.new(
          path: candidates.first,
          strategy: "normalized_filename",
          warnings: ["SOURCE_RESOLVED_BY_FILENAME"],
          page_marker_offset: 0
        )
      when 0
        raise SourceResolutionError, "No Markdown source resolved for #{adventure.source_book.inspect} under #{@source_root}"
      else
        raise AmbiguousSourceError, "Multiple Markdown sources match #{adventure.source_book.inspect}: #{candidates.join(', ')}"
      end
    end

    private

    # Return whether the supplied mapping declares segments; no validation or mutation occurs.
    def segmented_mapping?(value)
      value.is_a?(Hash) && (value.key?("segments") || value.key?(:segments))
    end

    # Select one fully containing segment for the request; return Resolution or raise a source/configuration error.
    def resolve_segmented_mapping(value, adventure)
      source_book = adventure.source_book
      segments = normalize_segmented_mapping(value, source_book: source_book)
      segments.each do |segment|
        path = absolute_or_rooted(segment.fetch(:file))
        unless File.file?(path)
          raise SourceResolutionError,
                "Configured source segment for #{source_book.inspect} does not exist: #{path}"
        end
      end
      start_page = adventure.start_page
      end_page = adventure.end_page
      unless start_page.is_a?(Integer) && end_page.is_a?(Integer)
        raise SourceResolutionError,
              "Segmented source mapping for #{source_book.inspect} requires integer adventure start_page and end_page"
      end
      if start_page > end_page
        raise SourceResolutionError,
              "Invalid adventure page range for #{source_book.inspect}: #{start_page}–#{end_page}"
      end

      matches = segments.select do |segment|
        start_page >= segment.fetch(:start_page) && end_page <= segment.fetch(:end_page)
      end
      if matches.empty?
        raise SourceResolutionError,
              "No configured source segment for #{source_book.inspect} contains adventure range #{start_page}–#{end_page}"
      end
      if matches.length > 1
        raise AmbiguousSourceError,
              "Multiple configured source segments for #{source_book.inspect} contain adventure range #{start_page}–#{end_page}"
      end

      mapping = matches.first
      path = absolute_or_rooted(mapping.fetch(:file))
      Resolution.new(
        path: path,
        strategy: "explicit_segment_mapping",
        warnings: [],
        page_marker_offset: mapping.fetch(:page_marker_offset)
      )
    end

    # Normalize selected scorer segments lazily; return mappings or raise ConfigurationError.
    def normalize_segmented_mapping(value, source_book:)
      incompatible = value.keys.map(&:to_s) - ["segments"]
      unless incompatible.empty?
        raise ConfigurationError,
              "Invalid source mapping for #{source_book.inspect}: segments cannot be combined with #{incompatible.join(', ')}"
      end

      raw_segments = value["segments"] || value[:segments]
      unless raw_segments.is_a?(Array) && !raw_segments.empty?
        raise ConfigurationError,
              "Invalid source mapping for #{source_book.inspect}: segments must be a non-empty list"
      end

      raw_segments.each_with_index.map do |segment, index|
        unless segment.is_a?(Hash)
          raise ConfigurationError,
                "Invalid source segment #{index + 1} for #{source_book.inspect}: expected mapping"
        end
        unknown = segment.keys.map(&:to_s) - %w[start_page end_page file page_marker_offset]
        unless unknown.empty?
          raise ConfigurationError,
                "Invalid source segment #{index + 1} for #{source_book.inspect}: unknown fields #{unknown.join(', ')}"
        end

        start_page = segment["start_page"] || segment[:start_page]
        end_page = segment["end_page"] || segment[:end_page]
        unless start_page.is_a?(Integer) && end_page.is_a?(Integer) && start_page.positive? && end_page.positive?
          raise ConfigurationError,
                "Invalid source segment #{index + 1} for #{source_book.inspect}: start_page and end_page must be positive integers"
        end
        if start_page > end_page
          raise ConfigurationError,
                "Invalid source segment #{index + 1} for #{source_book.inspect}: start_page exceeds end_page"
        end

        file = segment["file"] || segment[:file]
        unless file.is_a?(String) && !file.strip.empty?
          raise ConfigurationError,
                "Invalid source segment #{index + 1} for #{source_book.inspect}: file is required"
        end

        {
          start_page: start_page,
          end_page: end_page,
          file: file,
          page_marker_offset: normalize_page_marker_offset(
            segment["page_marker_offset"] || segment[:page_marker_offset] || "+0",
            source_book: source_book
          )
        }
      end
    end

    # Read the required scorer registry with aliases enabled; return lazy mappings or raise ConfigurationError.
    def load_registry(path)
      if path.nil? || path.to_s.strip.empty?
        raise ConfigurationError, "Source registry path is required"
      end

      expanded = File.expand_path(path)
      raise ConfigurationError, "Missing source registry: #{expanded}" unless File.file?(expanded)

      raw = YAML.safe_load_file(expanded, aliases: true) || {}
      unless raw.is_a?(Hash)
        raise ConfigurationError, "Invalid source registry #{expanded}: expected top-level mapping"
      end

      unknown = raw.keys.map(&:to_s) - %w[schema_version sources]
      unless unknown.empty?
        raise ConfigurationError,
              "Invalid source registry #{expanded}: unknown top-level fields #{unknown.join(', ')}"
      end

      version = raw["schema_version"] || raw[:schema_version]
      unless version == REGISTRY_SCHEMA_VERSION
        raise ConfigurationError,
              "Unsupported source registry schema #{version.inspect}; expected #{REGISTRY_SCHEMA_VERSION.inspect}"
      end

      sources = raw["sources"] || raw[:sources]
      unless sources.is_a?(Hash)
        raise ConfigurationError, "Invalid source registry #{expanded}: sources must be a mapping"
      end

      sources.each_with_object({}) do |(source_book, mapping), normalized|
        unless source_book.is_a?(String) && !source_book.strip.empty?
          raise ConfigurationError,
                "Invalid source registry #{expanded}: source-book keys must be nonblank strings"
        end
        normalized[source_book] = mapping
      end
    rescue Psych::Exception => e
      raise ConfigurationError, "Invalid source registry YAML #{path}: #{e.message}"
    end

    # Normalize one selected scorer mapping; return file/offset or raise ConfigurationError.
    def normalize_mapping(value, source_book:)
      unless value.is_a?(Hash)
        raise ConfigurationError,
              "Invalid source mapping for #{source_book.inspect}: expected mapping with file or segments"
      end

      unknown = value.keys.map(&:to_s) - %w[file page_marker_offset]
      unless unknown.empty?
        raise ConfigurationError,
              "Invalid source mapping for #{source_book.inspect}: unknown fields #{unknown.join(', ')}"
      end

      file = value["file"] || value[:file]
      unless file.is_a?(String) && !file.empty?
        raise ConfigurationError,
              "Invalid source mapping for #{source_book.inspect}: structured mapping requires file"
      end

      raw_offset = value["page_marker_offset"] || value[:page_marker_offset] || "+0"
      page_marker_offset = normalize_page_marker_offset(raw_offset, source_book: source_book)

      {
        file: file,
        page_marker_offset: page_marker_offset
      }
    end

    # Convert the supplied signed offset to Integer; raise ConfigurationError for unsupported text.
    def normalize_page_marker_offset(raw_offset, source_book:)
      offset_text = raw_offset.to_s
      unless offset_text.match?(/\A[+-]\d+\z/)
        raise ConfigurationError,
              "Invalid page_marker_offset for #{source_book.inspect}: use an explicitly signed value such as \"+3\" or \"-3\""
      end

      Integer(offset_text, 10)
    end

    # Expand a filename using existing absolute/rooted read policy; return the path.
    def absolute_or_rooted(value)
      Pathname.new(value).absolute? ? File.expand_path(value) : File.expand_path(value, @source_root)
    end

    # Return the cached sorted Markdown candidate paths beneath the selected source root.
    def markdown_files
      @markdown_files ||= Dir.glob(File.join(@source_root, "**", "*.md")).sort
    end

    # Return the existing Unicode/ASCII filename matching key for the supplied text.
    def normalize_source(value)
      ascii = value.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "")
      ascii.downcase.gsub("&", "and").gsub(/[^a-z0-9]+/, "")
    end

    # Return the existing legacy source key after removing supported edition suffixes.
    def normalize_filename(value)
      cleaned = value.to_s
        .sub(/_LLM_Edition.*\z/i, "")
        .sub(/[-_ ]LLM[-_ ]Edition.*\z/i, "")
        .sub(/\(\d+\)\z/, "")
      normalize_source(cleaned.tr("_", " "))
    end
  end
end
