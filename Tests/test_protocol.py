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



@pytest.mark.parametrize("version", ["v1", "v2", "v2Pro", "v2ProPlus"])
def test_imported_checkpoint_versions_are_accepted(job, tmp_path, version):
    for field, name in [("gptPath", "voice.ckpt"), ("sovitsPath", "voice.pth")]:
        checkpoint = tmp_path / name
        checkpoint.touch()
        job["voice"][field] = str(checkpoint)
    job["voice"]["modelVersion"] = version
    assert validate_job(job)[1]["modelVersion"] == version


def test_v1_requires_imported_pair_instead_of_missing_pretrained_weights(job):
    job["voice"]["modelVersion"] = "v1"
    with pytest.raises(ValueError, match="v1 voices need a matching"):
        validate_job(job)


@pytest.mark.parametrize("version", ["v3", "v4"])
def test_unsupported_versions_still_rejected(job, version):
    job["voice"]["modelVersion"] = version
    with pytest.raises(ValueError, match="Supported models"):
        validate_job(job)
