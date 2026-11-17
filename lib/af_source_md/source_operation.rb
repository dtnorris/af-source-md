# frozen_string_literal: true

module AFSourceMD
  # Publishes an explicitly selected Markdown file and a new v0.1 registry generation.
  # The caller owns approval and QA; this class verifies the bound files and publishes without clobbering.
  class SourceOperation
    API_VERSION = "af-source-md-operation/v0.1"
    KEYS = %w[schema_version library_id source_root operation_id revision action source_id edition
              destination registry prior_registry prior_source_id prior_sources page_marker_offset
              candidate qa context decision owner].freeze

    # Return the owner identity for a handoff or result; read failures propagate to the caller.
    def self.identity
      { "api_version" => API_VERSION, "root" => AFSourceMD::ROOT,
        "files" => $LOADED_FEATURES.grep(%r{/af_source_md(?:\.rb|/[^/]+\.rb)\z}).sort.to_h do |path|
          [Registry.relative_under_root!(AFSourceMD::ROOT, File.realpath(path), "source owner"), Registry.sha256(path)]
        end }
    end

    # Read the exact bytes and mode of a physically selected regular file; refuse aliases and special files.
    def self.snapshot(path)
      unless path.is_a?(String) && !path.include?("\0") && File.file?(path) && File.realpath(path) == path
        raise ValidationError, "Expected a canonical regular file: #{path.inspect}"
      end

      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        raise ValidationError, "Expected a regular file: #{path}" unless file.stat.file?
        bytes = file.binmode.read
        [{ "path" => path, "sha256" => Digest::SHA256.hexdigest(bytes),
           "bytes" => bytes.bytesize, "mode" => file.stat.mode & 0o777 }, bytes]
      end
    end

    # Resolve a normalized store-relative path with an existing physical parent; raise ValidationError on escape.
    def self.store_path!(root, relative)
      Registry.relative_filename!(relative, "store path")
      raise ValidationError, "Store path contains a NUL byte" if relative.include?("\0")
      path = File.expand_path(relative, root)
      unless path != root && Registry.relative_under_root!(root, path, "store path") == relative &&
             File.realpath(File.dirname(path)) == File.dirname(path) && !File.symlink?(path)
        raise ValidationError, "Store path must be canonical and must not traverse symlinks: #{relative.inspect}"
      end
      path
    end

    # Return the existing registry bytes/binding, mappings, and exact source bindings for a correction.
    # The registry and selected prior source must exist and satisfy v0.1 validation.
    def self.prior_state(root, registry, source_id)
      path = store_path!(root, registry)
      binding, bytes = snapshot(path)
      sources = Registry.parse_registry(bytes, path).fetch("sources")
      files = []
      if source_id
        entry = sources.fetch(source_id) { raise ValidationError, "Prior source is not registered: #{source_id.inspect}" }
        files = Registry.normalize_registry_entry(source_id, entry).fetch(:files).map do |filename|
          snapshot(store_path!(root, filename)).first
        end
      end
      [binding, bytes, sources, files]
    end

    # Under the store writer lock, get the caller-validated handoff and publish it.
    # Return attributable bindings. Refusals and file operation failures raise ValidationError.
    def self.publish!(source_root:)
      unless source_root.is_a?(String) && !source_root.include?("\0") &&
             File.realpath(source_root) == source_root && File.directory?(source_root)
        raise ValidationError, "Source root must be a canonical directory"
      end

      Registry.with_write_lock(source_root) do
        handoff = yield
        new(source_root, handoff).publish!
      end
    rescue SystemCallError => error
      raise ValidationError, "Source operation file access failed: #{error.message}"
    end

    private_class_method :new

    # Bind the versioned caller handoff to the locked root; reject unsupported operation shapes.
    def initialize(root, handoff)
      @root = root
      @handoff = handoff
      Registry.mapping!(handoff, "source operation")
      Registry.exact_keys!(handoff, KEYS, "source operation")
      Registry.require_keys!(handoff, KEYS, "source operation")
      unless handoff["schema_version"] == API_VERSION && handoff["source_root"] == root
        raise ValidationError, "Source operation schema or root does not match the selected owner"
      end
      %w[library_id operation_id edition].each { |key| Registry.nonblank_string!(handoff[key], key) }
      unless handoff["revision"].is_a?(Integer) && handoff["revision"] >= 0 &&
             %w[register correct].include?(handoff["action"])
        raise ValidationError, "Unsupported source operation action or revision"
      end
      @prior_id = handoff["prior_source_id"]
      if handoff["action"] == "correct"
        SourceRegister.validate_source_id!(@prior_id)
      elsif @prior_id
        raise ValidationError, "Registration cannot select a prior source"
      end
      @source_id = SourceRegister.validate_source_id!(handoff["source_id"])
      @offset = handoff["page_marker_offset"]
      SourceRegister.validate_offset!(@offset)
      %w[prior_registry candidate qa decision].each do |key|
        Registry.mapping!(handoff[key], "source operation #{key}")
      end
      unless handoff["context"].is_a?(Array) && handoff["context"].all? { |item| item.is_a?(Hash) }
        raise ValidationError, "Expected source operation context file bindings"
      end
      prior_path = Registry.nonblank_string!(handoff["prior_registry"]["path"], "prior registry path")
      @prior_registry = Registry.relative_under_root!(root, prior_path, "prior registry")
      unless handoff["prior_sources"].is_a?(Array) && handoff["owner"] == self.class.identity
        raise ValidationError, "Unsupported prior source bindings or changed source owner"
      end
      @destination = self.class.store_path!(root, handoff["destination"])
      @registry = self.class.store_path!(root, handoff["registry"])
      @journal = self.class.store_path!(root, "#{handoff['registry']}.source-operation.json")
      paths = [@destination, @registry, @journal, File.join(root, @prior_registry)]
      unless paths.uniq == paths && File.extname(@destination).downcase == ".md" && File.extname(@registry) == ".yml"
        raise ValidationError, "Source, retained registry, new .yml registry and operation record require distinct paths"
      end
    end

    # Plan from exact prior bytes, then publish the journal, source and registry in that order.
    # Uses immutable links for all three outputs. A retry verifies prior state and the durable plan.
    def publish!
      prior, original, mappings, prior_sources = verify_prior!
      candidate, markdown = verify_input!("candidate")
      verify_context!
      relative = @handoff.fetch("destination")
      SourceRegister.validate_unused_mapping!(mappings, @source_id, relative, root: @root)
      registry_bytes = SourceRegister.append_entry(original, @source_id, relative, @offset, empty_sources: mappings.empty?)
      result_sources = Registry.parse_registry(registry_bytes, @registry).fetch("sources")
      new_mapping = { "file" => relative }
      new_mapping["page_marker_offset"] = @offset if @offset
      unless result_sources == mappings.merge(@source_id => new_mapping)
        raise ValidationError, "Candidate registry changes prior mappings or does not contain the exact new mapping"
      end

      existing_source = existing_binding(@destination)
      source = candidate.merge("path" => @destination, "mode" => existing_source&.fetch("mode") || 0o600)
      registry = binding(@registry, registry_bytes, prior.fetch("mode"))
      existing_registry = existing_binding(@registry)
      existing_journal = existing_binding(@journal)
      result = {
        "schema_version" => API_VERSION, "owner" => self.class.identity, "source_root" => @root,
        "operation" => @handoff.slice("library_id", "operation_id", "revision", "action", "source_id", "edition", "prior_source_id"),
        "mapping" => new_mapping, "source" => source, "registry" => registry, "prior_registry" => prior,
        "prior_sources" => prior_sources, "decision" => @handoff.fetch("decision"), "qa" => @handoff.fetch("qa")
      }
      journal_bytes = JSON.generate({ "handoff" => @handoff, "result" => result })
      journal = binding(@journal, journal_bytes, 0o600)
      if existing_registry && (!existing_journal || existing_registry != registry || existing_source != source)
        raise ValidationError, "Conflicting or incomplete published registry: #{@registry}"
      end
      if existing_source && existing_source != source
        raise ValidationError, "Conflicting Markdown destination: #{@destination}"
      end
      if existing_journal && existing_journal != journal
        raise ValidationError, "Existing source operation record does not match this handoff and outputs"
      end

      publish_file!(journal, journal_bytes) unless existing_journal
      publish_file!(source, markdown) unless existing_source
      verify_prior!
      verify_input!("candidate")
      verify_context!
      unless existing_binding(@destination) == source
        raise ValidationError, "Markdown destination changed during source operation"
      end
      publish_file!(registry, registry_bytes) unless existing_registry
      unless existing_binding(@registry) == registry
        raise ValidationError, "Registry destination changed during source operation"
      end
      result.merge("journal" => journal, "reused" => !existing_registry.nil?)
    end

    private

    # Reload and verify the bound registry and any prior source files; return their snapshots and mappings.
    def verify_prior!
      state = self.class.prior_state(@root, @prior_registry, @prior_id)
      unless state[0] == @handoff["prior_registry"] && state[3] == @handoff["prior_sources"]
        raise ValidationError, "Prior registry or source identity changed"
      end
      state
    end

    # Recheck all supporting file bindings; editorial meaning remains with the caller.
    def verify_context!
      verify_input!("qa")
      verify_input!("decision")
      @handoff.fetch("context").each { |binding| verify_input!("context", binding) }
      raise ValidationError, "Source operation owner changed" unless self.class.identity == @handoff.fetch("owner")
    end

    # Recheck an input binding against disk and return its binding and bytes; refuse changed inputs.
    def verify_input!(key, expected = @handoff.fetch(key))
      actual, bytes = self.class.snapshot(expected["path"])
      raise ValidationError, "Source operation #{key} changed" unless actual == expected.slice(*actual.keys)

      [actual, bytes]
    end

    # Build a path, hash, size and mode binding for the supplied bytes.
    def binding(path, bytes, mode)
      { "path" => path, "sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize, "mode" => mode }
    end

    # Return a verified regular file binding or nil for an absent path. Refuse conflicting file types.
    def existing_binding(path)
      return nil unless File.exist?(path) || File.symlink?(path)

      self.class.snapshot(path).first
    end

    # Flush and link one fully staged file into its destination without replacement.
    # The temporary belongs only to this call; errors preserve the existing store.
    def publish_file!(target, bytes)
      path = target.fetch("path")
      parent = File.dirname(path)
      Tempfile.create([".source-operation-", ".tmp"], parent) do |temp|
        temp.binmode
        temp.write(bytes)
        temp.flush
        temp.chmod(target.fetch("mode"))
        temp.fsync
        unless self.class.snapshot(temp.path).first.merge("path" => path) == target
          raise ValidationError, "Staged source operation output does not match #{path}"
        end
        File.link(temp.path, path)
        File.open(parent, "rb", &:fsync)
      end
    rescue Errno::EEXIST
      raise ValidationError, "Source operation destination changed during publication: #{path}"
    end
  end
end
