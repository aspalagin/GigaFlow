#!/usr/bin/env python3
"""Offline, persistent GigaAM RNNT worker for the menu-bar dictation app.

Only stdout JSON lines are IPC; diagnostics go to stderr without transcripts.
The quiet-audio gate suppresses digital silence, not general background noise:
it is deliberately conservative and is not a trained voice activity detector.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
from pathlib import Path
import sys
import time
import uuid

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["DO_NOT_TRACK"] = "1"

SAMPLE_RATE = 16000
MAX_DURATION = 120.0
MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_REQUEST_BYTES = 16384
MIN_RMS = 0.0004
MIN_PEAK = 0.0015


class RequestError(ValueError):
    pass


def validate_request(message: object, audio_dir: Path) -> tuple[str, Path]:
    if not isinstance(message, dict) or message.get("type") != "transcribe":
        raise RequestError("Неизвестная команда распознавания.")
    request_id = message.get("id")
    if not isinstance(request_id, str) or len(request_id) > 64:
        raise RequestError("Некорректный идентификатор записи.")
    try:
        uuid.UUID(request_id)
    except ValueError as exc:
        raise RequestError("Некорректный идентификатор записи.") from exc
    value = message.get("path")
    if not isinstance(value, str) or not value or len(value) > 4096:
        raise RequestError("Не указан файл записи.")
    path = Path(value)
    if not path.is_absolute():
        raise RequestError("Требуется абсолютный путь к записи.")
    try:
        path = path.resolve(strict=True)
        path.relative_to(audio_dir)
    except (OSError, ValueError, RuntimeError) as exc:
        raise RequestError("Запись недоступна в папке приложения.") from exc
    if not path.is_file() or path.suffix.lower() not in {".wav", ".caf", ".aiff", ".aif", ".flac"}:
        raise RequestError("Неподдерживаемый формат записи.")
    if path.stat().st_size > MAX_FILE_BYTES:
        raise RequestError("Файл записи слишком большой.")
    return request_id, path


def chunk_ranges(audio, np, sample_rate: int = SAMPLE_RATE) -> list[tuple[int, int]]:
    """Partition all samples once, finding low-energy boundaries near 20 s.

    A prefix sum evaluates 200 ms windows in linear time. Without a pause,
    the quietest available boundary is used; continuous long speech can still
    split a word. No overlap/deduplication that could remove intentional repeats.
    """
    total = len(audio)
    maximum = 20 * sample_rate
    search_span = 4 * sample_rate
    window = max(1, sample_rate // 5)
    ranges = []
    start = 0
    while start < total:
        end = min(start + maximum, total)
        if end < total:
            search_start = max(start + maximum // 2, end - search_span)
            section = audio[search_start:end].astype(np.float64)
            prefix = np.concatenate(([0.0], np.cumsum(section * section)))
            energy = prefix[window:] - prefix[:-window]
            if len(energy):
                end = search_start + int(np.argmin(energy)) + window // 2
        ranges.append((start, end))
        start = end
    return ranges


def has_signal(audio, np) -> bool:
    if len(audio) < SAMPLE_RATE // 5:
        return False
    return bool(np.max(np.abs(audio)) >= MIN_PEAK and np.sqrt(np.mean(audio * audio)) >= MIN_RMS)


class Recognizer:
    def __init__(self, base: Path):
        # Keep any incidental third-party prints out of the IPC stream.
        with contextlib.redirect_stdout(sys.stderr):
            import librosa
            import mlx.core as mx
            import numpy as np
            import soundfile as sf
            from gigaam_mlx import load_model
            from gigaam_mlx.audio import compute_mel

            self.librosa, self.mx, self.np, self.sf = librosa, mx, np, sf
            self.compute_mel = compute_mel
            model_dir = base / "models/gigaam-v3-e2e-rnnt-mlx"
            if not model_dir.is_dir():
                raise RuntimeError("Локальная модель GigaAM не найдена.")
            self.model, self.tokenizer = load_model("rnnt", repo_id=str(model_dir))
            self.model.eval()
            # Initialize feature extraction and GPU before advertising readiness.
            self.decode(np.zeros(SAMPLE_RATE, dtype=np.float32))
            mx.synchronize()

    def decode(self, audio) -> str:
        mel = self.compute_mel(audio)
        encoded, seq_len = self.model.encode(self.mx.array(mel[self.np.newaxis]))
        self.mx.eval(encoded)
        text = self.tokenizer.decode(self.model.decode(encoded, seq_len))
        self.mx.synchronize()
        return text.strip()

    def transcribe(self, path: Path) -> tuple[str, float]:
        # O_NOFOLLOW rejects a final-component symlink introduced after validation.
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as raw:
            with self.sf.SoundFile(raw) as source:
                sr, channels, frames = source.samplerate, source.channels, len(source)
                if not 8000 <= sr <= 96000 or channels not in (1, 2):
                    raise RequestError("Неподдерживаемые параметры аудио.")
                duration = frames / sr
                if duration > MAX_DURATION:
                    raise RequestError("Запись превышает ограничение в 120 секунд.")
                if duration <= 0:
                    return "", 0.0
                audio = source.read(dtype="float32", always_2d=True).mean(axis=1)
        if not self.np.all(self.np.isfinite(audio)):
            raise RequestError("Файл содержит повреждённые аудиоданные.")
        if sr != SAMPLE_RATE:
            audio = self.librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE)
        if not has_signal(audio, self.np):
            return "", duration
        texts = []
        for start, end in chunk_ranges(audio, self.np):
            chunk = audio[start:end]
            if has_signal(chunk, self.np):
                text = self.decode(chunk)
                if text:
                    texts.append(text)
        return " ".join(texts), duration


def response_for(message: object, audio_dir: Path, recognizer) -> dict:
    request_id = message.get("id") if isinstance(message, dict) else None
    if not isinstance(request_id, str) or len(request_id) > 64:
        request_id = None
    try:
        request_id, path = validate_request(message, audio_dir)
        start = time.perf_counter()
        with contextlib.redirect_stdout(sys.stderr):
            text, duration = recognizer.transcribe(path)
        return {"type": "result", "id": request_id, "text": text,
                "duration": duration, "elapsed": time.perf_counter() - start}
    except RequestError as exc:
        return {"type": "error", "id": request_id, "message": str(exc)}
    except Exception as exc:
        # Do not put file contents, paths, transcripts or exception messages in logs.
        print(f"GigaAM request failed: {type(exc).__name__}", file=sys.stderr, flush=True)
        return {"type": "error", "id": request_id,
                "message": "Не удалось распознать запись. Попробуйте ещё раз."}


def emit(message: dict, output=None):
    print(json.dumps(message, ensure_ascii=False, allow_nan=False), file=output or sys.stdout, flush=True)


def serve(stream, output, audio_dir: Path, recognizer):
    while True:
        line = stream.readline(MAX_REQUEST_BYTES + 1)
        if not line:
            return
        if len(line) > MAX_REQUEST_BYTES:
            while line and not line.endswith("\n"):
                line = stream.readline(MAX_REQUEST_BYTES + 1)
            emit({"type": "error", "id": None, "message": "Команда слишком большая."}, output)
            continue
        try:
            message = json.loads(line)
        except (ValueError, TypeError):
            emit({"type": "error", "id": None, "message": "Некорректная команда."}, output)
            continue
        emit(response_for(message, audio_dir, recognizer), output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--audio-dir", type=Path, required=True)
    parser.add_argument("--self-test", type=Path, help="Recognize one file inside audio-dir and exit")
    args = parser.parse_args()
    try:
        audio_dir = args.audio_dir.resolve(strict=True)
        if not audio_dir.is_dir():
            raise ValueError("Not a directory")
        recognizer = Recognizer(args.base.resolve(strict=True))
    except Exception as exc:
        print(f"GigaAM initialization failed: {type(exc).__name__}", file=sys.stderr, flush=True)
        emit({"type": "fatal", "message": "Не удалось загрузить локальную GigaAM. Проверьте установку модели."})
        return 1
    emit({"type": "ready", "max_duration": MAX_DURATION, "backend": "MLX"})
    if args.self_test:
        result = response_for({"type": "transcribe", "id": str(uuid.uuid4()),
                               "path": str(args.self_test.absolute())}, audio_dir, recognizer)
        emit(result)
        return 0 if result["type"] == "result" else 1
    serve(sys.stdin, sys.stdout, audio_dir, recognizer)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
