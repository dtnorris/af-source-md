# af-source-md

Standalone Ruby 3.2+ source registry, registration, resolution and raw Markdown
mechanics. Load with `require "af_source_md"` using this tree's `lib` directory
on the Ruby load path. Dependencies are Ruby's date, digest, fileutils, json,
pathname, tempfile, time and yaml libraries. Neither pipeline nor scorer is a
runtime dependency. `API_VERSION` is `af-source-md/v0.1`.

To read a printed page range, give `AFSourceMD::SourceResolver` the source
directory and its v0.1 registry. Resolve a request with the source-book name
and page bounds, open the returned path with `AFSourceMD::SourceDocument`,
and pass the same bounds and the resolved `page_marker_offset` to `extract`.
The result’s `text` contains the selected Markdown bytes, including its markers.
The [standalone example](test/mechanics_test.rb) registers a synthetic source
and checks the exact bytes returned for two pages.

Run the content-free standalone conformance test with
`ruby -Ilib test/mechanics_test.rb` (Minitest is a test-only dependency).

`Registry` provides the pipeline's strict v0.1 envelope/entry/path/hash checks.
`SourceIdentity.validate!(value, error_class:)` validates an explicit identity.
`SourceRegister.register!(source_root:, source_id:, markdown_path:,
registry_path: nil, page_marker_offset: nil)` appends one explicit mapping to an
**existing** registry. It returns a Result with registry path, identity, filename,
before/after registry hashes and the supplied offset. Candidate validation,
prior-byte comparison, comments, permissions and owned temporary cleanup remain
part of the append contract. Registration shares the source-root advisory
writer lock with guarded operations when both use this owner and the same
physical source root.

### Guarded source writes

`SourceOperation.publish!(source_root:) { handoff }` accepts a
`af-source-md-operation/v0.1` handoff supplied by the caller after it verifies
the operator's decision, QA and editorial context. The block runs under the
source-root writer lock. The handoff binds the exact owner, library and root,
operation and revision, action, explicit source ID and edition, placement path
and single-file mapping, candidate, prior registry and correction source file
bindings, decision and supporting context. Regular-file bindings use canonical
absolute path, byte size, SHA-256 and mode. The owner validates those bindings,
the v0.1 mappings and physical store paths. The pipeline ingest runbook defines
the operator decision interface.

Publication links an operation record, exact Markdown and a new registry
generation, in that order. The registry is the commit point. The old registry,
prior mappings and old source paths remain available for frozen consumers. The
new registry carries the previous mode, and an exact pre-existing Markdown file
keeps its bytes and mode. Corrections add an explicit new source identity.
Readers select the new registry path from the returned bindings.

A retry under the same binding checks the operation record and the already
published files, then links only missing outputs. Conflicts refuse without
replacing a destination. Normal error handling cleans up temporaries owned by
that invocation. A process killed while staging can leave a hidden temporary.
The lock coordinates writers using this owner and the same physical source
root. External writers need to honor the same store boundary.

`SourceResolver.new(source_root:, registry_path:).resolve(request)` accepts an
object exposing `source_book`, `start_page` and `end_page`. Its Resolution supplies
path, strategy, warnings and integer page-marker offset. Registry entries are
checked lazily using the established scorer read policy, including warned
filename fallback and complete segment containment. Pipeline validation remains
stricter about relative paths, signed String offsets, segment order and overlap;
these are explicit compatibility differences, not permission to tighten readers.

`SourceDocument.new(path).extract(start_page:, end_page:, page_marker_offset: 0,
allow_full_source_fallback: false, allow_inward_boundary_clamp: false,
max_inward_boundary_clamp_gap: 1)` returns text, source_file, scope, original
canonical endpoints and warnings. Printed markers take precedence over fallback
markers. Offsets and slices count bytes through EOF; no stripping or normalization
occurs. Callers grant fallback/clamp permission and retain their context policy.
`page_markers` supplies the marker inventory; `byteslice(range)` reads only the
already loaded text for caller context selection, with String#byteslice semantics.

Mechanical refusals use `AFSourceMD::ValidationError`, `ConfigurationError`,
`SourceResolutionError` (including `AmbiguousSourceError`) or `SourceBoundaryError`.
Unexpected Ruby argument/filesystem errors retain their native type except for
the established registration file-operation translation. Adapters retain caller
result types, errors, sequencing and policy. No source registration or raw read
grants QA/editorial approval, replay qualification, storage initialization,
or downstream publication authority.

Pipeline and public scorer adapters support an authoritative absolute
`AF_SOURCE_MD_ROOT` pointing to this tree, or an ordinary installed
`require "af_source_md"` when the selector is absent. Explicit missing, invalid
or unsupported selection refuses without fallback. Keep selection fixed for the
process lifetime. `ROOT`, `API_VERSION` and observed loaded-file hashes identify
the selected code; the selector is not a sandbox or authentication mechanism.
Installation and release are separate operator decisions.

This package implements the representation boundary selected by the accepted
OS-MD-04 report and OS-MD-05 input contract. Existing registry v0.1 and scorer
prepared-source v0.2 remain unchanged; scorer owns frozen replay and Levels
context, and pipeline owns artifact/editorial workflow. This README describes
the supported package API, not an adoption or qualification receipt.
