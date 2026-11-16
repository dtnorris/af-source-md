# af-source-md

Standalone Ruby 3.2+ source registry, registration, resolution and raw Markdown
mechanics. Load with `require "af_source_md"` using this tree's `lib` directory
on the Ruby load path. Dependencies are Ruby's date, digest, fileutils, json,
pathname, tempfile, time and yaml libraries. Neither pipeline nor scorer is a
runtime dependency. `API_VERSION` is `af-source-md/v0.1`.

Run the content-free standalone conformance test with
`ruby -Ilib test/mechanics_test.rb` (Minitest is a test-only dependency).

`Registry` provides the pipeline's strict v0.1 envelope/entry/path/hash checks.
`SourceIdentity.validate!(value, error_class:)` validates an explicit identity.
`SourceRegister.register!(source_root:, source_id:, markdown_path:,
registry_path: nil, page_marker_offset: nil)` appends one explicit mapping to an
**existing** registry. It returns a Result with registry path, identity, filename,
before/after registry hashes and the supplied offset. Candidate validation,
prior-byte comparison, comments, permissions and owned temporary cleanup remain
part of the append contract. The compare/rename sequence does not provide locking
or a cross-store transaction.

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
approved correction or publication authority.

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
