# af-source-md

Given a book name and a printed page range, `af-source-md` finds the matching
Markdown file and returns the exact excerpt, including its page markers.
[Adventure Finder](https://github.com/dtnorris/adventure-finder) uses this Ruby
library so a catalog entry can lead back to the text of the book.

**Using your own books?** Clone this public repository for the code. For the
full Adventure Finder workflow, create a private `af-source-md-data` repository
in your own account or organization. Keep the page-marked Markdown from your
books and its source registry there. The example below runs entirely in a
temporary directory. [Private repository setup](https://github.com/dtnorris/adventure-finder#set-up-your-own-private-repositories)

## Read one printed page

Run this from the repository root with Ruby 3.2 or later. It uses the Ruby
standard library. The two-page sample makes it easy to see where the excerpt
starts and ends.

```sh
ruby -Ilib -raf_source_md -rtmpdir <<'RUBY'
Dir.mktmpdir do |root|
  File.write(File.join(root, "sample.md"), <<~MARKDOWN)
    <!-- Printed Page 1 -->
    First page.
    <!-- Printed Page 2 -->
    Second page.
  MARKDOWN
  registry = File.join(root, "source_registry.yml")
  File.write(registry, <<~YAML)
    schema_version: adventurefinder-source-registry/v0.1
    sources:
      Sample: {file: sample.md}
  YAML

  request = Struct.new(:source_book, :start_page, :end_page).new("Sample", 2, 2)
  resolver = AFSourceMD::SourceResolver.new(source_root: root, registry_path: registry)
  source = resolver.resolve(request)
  page = AFSourceMD::SourceDocument.new(source.path).extract(
    start_page: request.start_page, end_page: request.end_page,
    page_marker_offset: source.page_marker_offset
  )
  print page.text
end
RUBY
```

Expected output:

```text
<!-- Printed Page 2 -->
Second page.
```

To read your own library, point `source_root:` at the private Markdown
directory and `registry_path:` at its registry. Supply the source-book name
and inclusive page bounds from your catalog. Pass the resolver’s
`page_marker_offset` through to extraction so the requested catalog pages map
to the right markers in that file.

## Which API do I need?

| Task | Entry point | What to expect |
| --- | --- | --- |
| Find the source for a page range | [`SourceResolver#resolve`](lib/af_source_md/source_resolver.rb) | Returns a path, strategy, warnings, and page-marker offset. For a segmented book, one segment must contain the whole range. |
| Read the text at those pages | [`SourceDocument#extract`](lib/af_source_md/source_document.rb) | Returns the original text, source path, scope, requested bounds, and warnings. Printed page markers take precedence over PDF page markers. |
| Check inputs before registering a source | [`Registry`](lib/af_source_md/registry.rb) and [`SourceIdentity`](lib/af_source_md/source_identity.rb) | Apply the strict registration checks to the registry and source identity. The resolver checks the mapping selected for a read. |
| Add a file to an existing registry | [`SourceRegister.register!`](lib/af_source_md/source_register.rb) | Appends an explicit source ID and Markdown path. Returns the registry path and its before/after hashes. |
| Publish an approved source or correction | [`SourceOperation.publish!`](lib/af_source_md/source_operation.rb) | Publishes the source and a new registry generation under the source-root writer lock. |

For automated readers, inspect `source.strategy` and `source.warnings`: when
a name has no explicit mapping, a unique filename match can resolve with a
warning. Missing required page markers raise `AFSourceMD::SourceBoundaryError`
by default. Whole-source fallback and inward boundary clamping are explicit
options. If you enable either, retain the extraction’s `scope` and `warnings`
alongside its text.

### Guarded source writes

The [pipeline ingest runbook](https://github.com/dtnorris/af-pipeline/blob/main/docs/LIBRARY_INGEST_RUNBOOK.md)
describes how an operator reviews and approves a source. The pipeline supplies
the approved handoff to `SourceOperation.publish!`. The library verifies its
file bindings and publishes the operation record, Markdown, and new registry
in that order. The new registry is the commit point. Readers can keep using
the previous generation, and a retry with the same bindings can finish a
partial publication. Conflicting files cause a refusal.

## Integrate and test

Load the library with `require "af_source_md"` and this checkout’s `lib`
directory on Ruby’s load path. For pipeline and scorer integrations,
`AF_SOURCE_MD_ROOT` selects the **public code checkout** by absolute path.
The private Markdown directory is the separate `source_root:` input.
The API version is `af-source-md/v0.1`.

With Minitest available, run the [standalone mechanics tests](test/mechanics_test.rb)
from the repository root:

```sh
ruby -Ilib test/mechanics_test.rb
```

[MIT License](LICENSE)
