# frozen_string_literal: true
source "https://rubygems.org"

# Quality scorer: pure-Ruby FineWeb-Edu inference + HTML extraction.
gem "onnxruntime"   # runs the ONNX classifier (vendor/fwedu/model.onnx)
gem "tokenizers"    # loads the model's tokenizer.json (HF tokenizers, identical to Python)
gem "nokogiri"      # main-content HTML extraction

group :web do
  gem "sinatra"
  gem "puma"
  gem "rackup"
end
