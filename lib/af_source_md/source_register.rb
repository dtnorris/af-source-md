# frozen_string_literal: true

module AFSourceMD
  # Appends one explicit single-file source mapping to the corpus-owned registry.
  # It never infers source identity, segments, or page-marker offsets.
  class SourceRegister
    Result = Data.define(
      :registry_path, :source_id, :filename, :registry_sha256_before,
      :registry_sha256_after, :page_marker_offset
    )

    # Register the supplied root, identity, Markdown and optional offset; return Result or raise ValidationError.
    def self.register!(source_root:, source_id:, markdown_path:, registry_path: nil,
                       page_marker_offset: nil)
      new(
        source_root:, source_id:, markdown_path:, registry_path:,
        page_marker_offset:
      ).register!
    end

    # Bind the supplied paths/options to this mechanical reader or writer; loading may raise owner errors.
    def initialize(source_root:, source_id:, markdown_path:, registry_path:, page_marker_offset:)
      @source_root = source_root
      @source_id = source_id
      @markdown_path = markdown_path
      @registry_path = registry_path
      @page_marker_offset = page_marker_offset
    end

    # Append one explicit source mapping; return Result, or raise ValidationError without publishing an invalid candidate.
    def register!
      root = Registry.expanded_source_root(@source_root)
      source_id = Registry.nonblank_string!(@source_id, "source_id")
      raise ValidationError, "source_id must be a single line" if source_id.match?(/[\r\n]/)
      source_id = SourceIdentity.validate!(source_id, error_class: ValidationError)

      markdown = Registry.existing_file!(@markdown_path, "Markdown source")
      relative = Registry.relative_under_root!(root, markdown, "Markdown source")
      raise ValidationError, "Markdown source must end in .md: #{relative}" unless File.extname(relative).downcase == ".md"
      validate_offset!(@page_marker_offset)

      registry = Registry.registry_context(root, @registry_path)
      registry_path = registry.fetch("path")
      sources = registry.fetch("sources")
      if sources.key?(source_id)
        raise ValidationError, "Source registry already contains source identity #{source_id.inspect}"
      end

      existing_refs = sources.filter_map do |existing_id, entry|
        normalized = Registry.normalize_registry_entry(existing_id, entry)
        existing_id if normalized.fetch(:files).include?(relative)
      end
      unless existing_refs.empty?
        raise ValidationError,
              "Markdown file #{relative.inspect} is already registered to: #{existing_refs.sort.join(', ')}"
      end

      original = File.binread(registry_path)
      before_sha = Digest::SHA256.hexdigest(original)
      candidate = append_entry(original, source_id, relative, @page_marker_offset, empty_sources: sources.empty?)
      mode = File.stat(registry_path).mode & 0o777
      temp_path = nil

      begin
        Tempfile.create([".source-registry-", ".yml"], File.dirname(registry_path)) do |temp|
          temp_path = temp.path
          temp.binmode
          temp.write(candidate)
          temp.flush
          temp.fsync
          File.chmod(mode, temp.path)

          temp_registry = Registry.registry_context(root, temp.path)
          entry = temp_registry.fetch("sources")[source_id]
          raise ValidationError, "candidate registry did not contain new source identity" unless entry
          normalized = Registry.normalize_registry_entry(source_id, entry)
          unless normalized.fetch(:files) == [relative] && normalized[:segments].nil?
            raise ValidationError, "candidate registry mapping did not validate as one explicit file"
          end

          current = File.binread(registry_path)
          raise ValidationError, "source registry changed during source-register" unless current == original
          File.rename(temp.path, registry_path)
          temp_path = nil
        end
      ensure
        FileUtils.rm_f(temp_path) if temp_path
      end

      final_registry = Registry.registry_context(root, registry_path)
      final_entry = final_registry.fetch("sources")[source_id]
      raise ValidationError, "registered source identity missing after publish" unless final_entry
      after_sha = Registry.sha256(registry_path)

      Result.new(
        registry_path:,
        source_id:,
        filename: relative,
        registry_sha256_before: before_sha,
        registry_sha256_after: after_sha,
        page_marker_offset: @page_marker_offset
      )
    rescue SystemCallError => e
      raise ValidationError, "source-register file operation failed: #{e.message}"
    end

    private

    # Validate the supplied explicitly signed offset; return nil or raise ValidationError.
    def validate_offset!(value)
      return if value.nil?
      unless value.is_a?(String) && /\A[+-]\d+\z/.match?(value)
        raise ValidationError, "--page-marker-offset must be an explicitly signed integer such as +3 or -1"
      end
    end

    # Returns UTF-8 registry bytes with one explicit file/optional signed offset
    # appended. When the validated sources map is empty, opens a plain
    # `sources: {}` header without reserializing comments or existing mappings;
    # unsupported layouts still face candidate validation.
    # Raises ValidationError when the original bytes are not valid UTF-8.
    def append_entry(original, source_id, relative, offset, empty_sources:)
      content = original.dup.force_encoding(Encoding::UTF_8)
      unless content.valid_encoding?
        raise ValidationError, "source registry must be valid UTF-8"
      end

      if empty_sources
        content.sub!(/^sources:([ \t]*)\{[ \t]*\}([ \t]*(?:#[^\r\n]*)?)(\r?)$/, 'sources:\1\2\3')
      end
      content << "\n" unless content.end_with?("\n")
      content << "\n"
      content << "  #{JSON.generate(source_id)}:\n"
      content << "    file: #{JSON.generate(relative)}\n"
      content << "    page_marker_offset: #{JSON.generate(offset)}\n" if offset
      content
    end

  end
end
