# frozen_string_literal: true

module AFSourceMD
  # Raw Markdown marker inventory and byte-exact page extraction.
  class SourceDocument
    Extraction = Struct.new(
      :text, :source_file, :scope, :start_page, :end_page, :warnings, keyword_init: true
    )

    PRINTED_PAGE_MARKER = /^\s*(?:>\s*)*<!--\s*Printed\s+Page\s+(\d+)\s*-->\s*$/i
    FALLBACK_PAGE_MARKER = /^\s*(?:>\s*)*<!--\s*(?:PDF\s+Page|PAGE:)\s*(\d+)\s*-->\s*$/i
    MAX_BOUNDARY_MARKER_GAP = 1

    # Bind the supplied paths/options to this mechanical reader or writer; loading may raise owner errors.
    def initialize(path)
      @path = File.expand_path(path)
      raise SourceResolutionError, "Source file does not exist: #{@path}" unless File.file?(@path)
      @text = File.read(@path, encoding: "UTF-8")
    end

    # Extract the exact source bytes for canonical pages adjusted by page_marker_offset.
    # Returns an Extraction with canonical endpoints, scope and boundary warnings;
    # explicit fallback/clamp options retain their unverified/clamped metadata.
    # Raises SourceBoundaryError for refused boundaries (ArgumentError/TypeError
    # for an invalid clamp gap). Marker offsets and the EOF endpoint count bytes.
    def extract(
      start_page:,
      end_page:,
      page_marker_offset: 0,
      allow_full_source_fallback: false,
      allow_inward_boundary_clamp: false,
      max_inward_boundary_clamp_gap: MAX_BOUNDARY_MARKER_GAP
    )
      unless start_page && end_page
        return fallback_or_raise("Canonical Start Page / End Page are unavailable", allow_full_source_fallback)
      end
      raise SourceBoundaryError, "Start page #{start_page} exceeds end page #{end_page}" if start_page > end_page

      markers = page_markers
      if markers.empty?
        return fallback_or_raise("No supported page markers found in #{@path}", allow_full_source_fallback)
      end

      marker_start_page = start_page + page_marker_offset
      marker_end_page = end_page + page_marker_offset
      if allow_inward_boundary_clamp
        max_gap = Integer(max_inward_boundary_clamp_gap)
        raise SourceBoundaryError, "Inward boundary clamp max gap must be at least 1" if max_gap < 1

        start_marker, start_warning = boundary_start_marker(
          markers, marker_start_page, marker_end_page, max_gap
        )
        end_marker_index, end_warning = boundary_end_marker_index(
          markers, marker_start_page, marker_end_page, max_gap
        )
      else
        start_marker = markers.find { |m| m[:page] == marker_start_page }
        end_marker_index = markers.index { |m| m[:page] == marker_end_page }
        start_warning = nil
        end_warning = nil
      end
      unless start_marker && end_marker_index
        missing = []
        missing << marker_start_page unless start_marker
        missing << marker_end_page unless end_marker_index
        offset = format("%+d", page_marker_offset)
        return fallback_or_raise(
          "Required source page marker(s) not found: #{missing.uniq.join(', ')} " \
          "(canonical #{start_page}-#{end_page}, page_marker_offset #{offset})",
          allow_full_source_fallback
        )
      end

      start_offset = start_marker[:offset]
      next_marker = markers[end_marker_index + 1]
      end_offset = next_marker ? next_marker[:offset] : @text.bytesize
      if end_offset <= start_offset
        return fallback_or_raise("Page marker ordering is inconsistent for #{marker_start_page}-#{marker_end_page}", allow_full_source_fallback)
      end

      warnings = [start_warning, end_warning].compact
      Extraction.new(
        text: @text.byteslice(start_offset...end_offset),
        source_file: @path,
        scope: warnings.empty? ? "canonical_page_slice" : "canonical_page_slice_boundary_clamped",
        start_page: start_page,
        end_page: end_page,
        warnings: warnings
      )
    end

    # Return cached page/byte-offset records, preferring Printed markers over fallback conventions.
    def page_markers
      @page_markers ||= begin
        printed = markers_for(PRINTED_PAGE_MARKER)
        printed.empty? ? markers_for(FALLBACK_PAGE_MARKER) : printed
      end
    end

    # Read the already loaded source at a byte Range for caller context selection.
    # Returns String or nil using String#byteslice semantics; invalid ranges raise
    # ordinary TypeError/RangeError. No normalization or boundary policy is added.
    def byteslice(range)
      @text.byteslice(range)
    end

    private

    # Return an exact or permitted inward start marker and warning, or nils when unavailable.
    def boundary_start_marker(markers, requested_page, range_end_page, max_gap)
      exact = markers.find { |marker| marker[:page] == requested_page }
      return [exact, nil] if exact

      (1..max_gap).each do |gap|
        candidate_page = requested_page + gap
        break if candidate_page > range_end_page

        candidate = markers.find { |marker| marker[:page] == candidate_page }
        next unless candidate

        return [
          candidate,
          "SOURCE_BOUNDARY_START_MARKER_MISSING: requested source page #{requested_page}; " \
            "clamped inward to page #{candidate_page}"
        ]
      end

      [nil, nil]
    end

    # Return an exact or permitted inward end index and warning, or nils when unavailable.
    def boundary_end_marker_index(markers, range_start_page, requested_page, max_gap)
      exact_index = markers.index { |marker| marker[:page] == requested_page }
      return [exact_index, nil] if exact_index

      (1..max_gap).each do |gap|
        candidate_page = requested_page - gap
        break if candidate_page < range_start_page

        candidate_index = markers.index { |marker| marker[:page] == candidate_page }
        next unless candidate_index

        return [
          candidate_index,
          "SOURCE_BOUNDARY_END_MARKER_MISSING: requested source page #{requested_page}; " \
            "clamped inward to page #{candidate_page}"
        ]
      end

      [nil, nil]
    end

    # Return page/byte-offset records for the supplied pattern without normalizing source bytes.
    def markers_for(pattern)
      offsets = []
      cursor = 0
      @text.each_line do |line|
        if (match = line.match(pattern))
          offsets << { page: match[1].to_i, offset: cursor }
        end
        cursor += line.bytesize
      end
      offsets
    end

    # Return a full-source Extraction only when permitted; otherwise raise SourceBoundaryError.
    def fallback_or_raise(message, allow)
      raise SourceBoundaryError, message unless allow
      Extraction.new(
        text: @text,
        source_file: @path,
        scope: "full_source_fallback",
        start_page: nil,
        end_page: nil,
        warnings: ["SOURCE_BOUNDARY_UNVERIFIED", message]
      )
    end
  end
end
