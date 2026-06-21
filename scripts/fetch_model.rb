# frozen_string_literal: true

# Download the FineWeb-Edu classifier (ONNX) + tokenizer into vendor/fwedu/.
# The model is ~438 MB, so it is fetched on demand rather than committed.
#   ruby scripts/fetch_model.rb

require "open-uri"
require "fileutils"

BASE = "https://huggingface.co/davanstrien/fineweb-edu-classifier-onnx/resolve/main/onnx"
DIR = File.expand_path("../vendor/fwedu", __dir__)
FileUtils.mkdir_p(DIR)

{ "model.onnx" => "#{BASE}/model.onnx", "tokenizer.json" => "#{BASE}/tokenizer.json" }.each do |name, url|
  dest = File.join(DIR, name)
  if File.exist?(dest) && File.size(dest) > 1000
    warn "have #{name} (#{(File.size(dest) / 1_048_576.0).round(1)} MB)"
    next
  end
  warn "downloading #{name} ..."
  URI.parse(url).open("User-Agent" => "ruby-scorecard") { |f| IO.copy_stream(f, dest) }
end
warn "done -> #{DIR}"
