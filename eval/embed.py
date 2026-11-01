"""Reusable gloss embedding for kakehashi RQ3.

MiniLM (all-MiniLM-L6-v2) via fastembed/ONNX — no torch, CPU-fine. Kept as a
tiny module so it can be lifted into an HTTP sidecar later without change.
Both the native (JMdict) and Sinitic (Unihan) glosses are English, so a
monolingual model is sufficient.
"""
from __future__ import annotations

import os
from functools import lru_cache

import numpy as np

# Requested model; override with KAKEHASHI_EMBED_MODEL. Falls back to a model
# fastembed ships if the requested one is unavailable in this fastembed version.
MODEL = os.environ.get("KAKEHASHI_EMBED_MODEL", "sentence-transformers/all-MiniLM-L6-v2")
FALLBACK = "BAAI/bge-small-en-v1.5"


@lru_cache(maxsize=1)
def _model():
    from fastembed import TextEmbedding

    try:
        return TextEmbedding(model_name=MODEL), MODEL
    except Exception as exc:  # unsupported model name in this fastembed build
        print(f"[embed] {MODEL} unavailable ({exc}); falling back to {FALLBACK}")
        return TextEmbedding(model_name=FALLBACK), FALLBACK


def model_name() -> str:
    return _model()[1]


def embed(texts) -> np.ndarray:
    """L2-normalized (n, d) float32 embeddings, so a dot product is cosine."""
    model, _ = _model()
    vecs = np.asarray(list(model.embed(list(texts))), dtype=np.float32)
    norms = np.linalg.norm(vecs, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return vecs / norms
