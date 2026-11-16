# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "af-source-md"
  spec.version = "0.1.0"
  spec.summary = "Standalone AdventureFinder source registry and raw Markdown mechanics"
  spec.authors = ["David Norris"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = File.readlines(File.join(__dir__, "Manifest.txt"), chomp: true)
  spec.require_paths = ["lib"]
end
