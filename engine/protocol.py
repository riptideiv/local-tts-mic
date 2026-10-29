"""Validation at the native app / Python worker boundary."""
from pathlib import Path
import uuid

LANGUAGES = {"auto", "en", "zh", "ja"}
VERSIONS = {"v2", "v2Pro", "v2ProPlus"}


def validate_job(command):
    job_id = command.get("id", "")
    uuid.UUID(job_id)  # Also keeps job IDs safe as filenames.
    text = command.get("text", "").strip()
    if not text or len(text) > 4000:
        raise ValueError("Enter between 1 and 4,000 characters.")
    if command.get("language") not in LANGUAGES:
        raise ValueError("Choose English, Mandarin, Japanese, or Auto.")
    voice = command["voice"]
    if voice.get("language") not in LANGUAGES - {"auto"}:
        raise ValueError("Set the reference clip's spoken language.")
    if not voice.get("transcript", "").strip():
        raise ValueError("The reference clip needs its exact transcript.")
    if voice.get("modelVersion") not in VERSIONS:
        raise ValueError("Supported models: v2, v2Pro, v2ProPlus.")
    if not Path(voice.get("referencePath", "")).is_file():
        raise ValueError("The reference clip is missing. Edit this voice and choose it again.")
    pair = [voice.get("gptPath", ""), voice.get("sovitsPath", "")]
    if any(pair) and not all(pair):
        raise ValueError("Choose both the GPT and SoVITS checkpoints.")
    for p in filter(None, pair):
        if not Path(p).is_file():
            raise ValueError(f"Checkpoint is missing: {Path(p).name}")
    speed = float(command.get("speed", voice.get("speed", 1)))
    if not 0.5 <= speed <= 2:
        raise ValueError("Speed must be between 0.5× and 2×.")
    return text, voice, speed

