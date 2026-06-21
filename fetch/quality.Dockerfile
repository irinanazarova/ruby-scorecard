# Disposable image for the training-data quality probe (FineWeb-Edu classifier).
# CPU torch + transformers; the ~440MB classifier is baked in at build time so the run is offline-fast.
FROM python:3.11-slim
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu \
 && pip install --no-cache-dir "transformers>=4.44" "huggingface_hub>=0.24"
# Pre-download the classifier into the image cache.
RUN python -c "from transformers import AutoTokenizer, AutoModelForSequenceClassification as M; \
m='HuggingFaceFW/fineweb-edu-classifier'; AutoTokenizer.from_pretrained(m); M.from_pretrained(m)"
WORKDIR /app
COPY scripts/quality.py scripts/quality.py
COPY data/scorecard.json data/scorecard.json
COPY data/coverage_details.json data/coverage_details.json
COPY data/quality_experiment.json data/quality_experiment.json
CMD ["sleep", "infinity"]
