#!/usr/bin/env python3
"""A tiny, localhost-only Chatterbox endpoint for My Man.

This intentionally implements only POST /v1/audio/speech. It never binds to
the network, stores prompts, or phones home. The first request downloads the
model through the Chatterbox package's normal Hugging Face cache.
"""
import io

import torch
import torchaudio
from chatterbox.tts import ChatterboxTTS
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel


class SpeechRequest(BaseModel):
    model: str = "chatterbox"
    input: str
    voice: str = "default"
    response_format: str = "wav"


device = "mps" if torch.backends.mps.is_available() else "cpu"
model = ChatterboxTTS.from_pretrained(device=device)
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/health")
def health():
    return {"status": "ready"}


@app.post("/v1/audio/speech")
def speech(request: SpeechRequest):
    text = request.input.strip()
    if not text:
        raise HTTPException(status_code=400, detail="input is required")
    try:
        wav = model.generate(text)
        output = io.BytesIO()
        torchaudio.save(output, wav.cpu(), model.sr, format="wav")
        return Response(content=output.getvalue(), media_type="audio/wav")
    except Exception as error:
        raise HTTPException(status_code=500, detail=str(error)) from error
