# Quality-checker service (Ruby/Sinatra) with the FineWeb-Edu ONNX model baked in.
FROM ruby:3.4-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates libstdc++6 && rm -rf /var/lib/apt/lists/*
RUN gem install --no-document onnxruntime tokenizers nokogiri sinatra puma rackup
WORKDIR /app
COPY scripts/quality_core.rb scripts/quality_core.rb
COPY scripts/fetch_model.rb scripts/fetch_model.rb
RUN ruby scripts/fetch_model.rb           # bake the ~438MB model (cached unless fetch_model.rb changes)
COPY web/ web/
ENV FWEDU_ONNX=/app/vendor/fwedu/model.onnx
ENV FWEDU_TOKENIZER=/app/vendor/fwedu/tokenizer.json
ENV PORT=8080
EXPOSE 8080
CMD ["ruby", "web/check.rb"]
