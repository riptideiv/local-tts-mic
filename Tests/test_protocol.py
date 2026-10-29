import sys
from pathlib import Path
import uuid

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
from protocol import validate_job


@pytest.fixture
def job(tmp_path):
    ref = tmp_path / "日本語.wav"
    ref.write_bytes(b"reference placeholder; duration is checked by the worker")
    return dict(id=str(uuid.uuid4()), text="こんにちは。你好。Hello.", language="auto", speed=1,
                voice=dict(referencePath=str(ref), language="ja", transcript="水をマレーシアから買わなくてはならないのです。", modelVersion="v2ProPlus"))


def test_multilingual_reference_is_preserved(job):
    text, voice, speed = validate_job(job)
    assert text == "こんにちは。你好。Hello."
    assert voice["transcript"].endswith("のです。")


@pytest.mark.parametrize("field,value", [("id", "../../escape"), ("text", " "), ("text", "字" * 4001), ("language", "unsupported"), ("speed", 0), ("speed", float("nan"))])
def test_rejects_bad_commands_before_inference(job, field, value):
    job[field] = value
    with pytest.raises(ValueError):
        validate_job(job)


def test_rejects_partial_checkpoint_pair(job, tmp_path):
    checkpoint = tmp_path / "speaker.ckpt"
    checkpoint.touch()
    job["voice"]["gptPath"] = str(checkpoint)
    with pytest.raises(ValueError, match="both"):
        validate_job(job)


def test_missing_reference_is_actionable(job):
    Path(job["voice"]["referencePath"]).unlink()
    with pytest.raises(ValueError, match="reference clip is missing"):
        validate_job(job)

