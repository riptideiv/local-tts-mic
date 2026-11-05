"""Small, restartable model/voice installer. No speech is sent to a service."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("LOCALSPEAK_ROOT", ROOT)) / "runtime"
GSV = RUNTIME / "GPT-SoVITS"
MODELS = GSV / "GPT_SoVITS/pretrained_models"
CHECKSUMS = json.loads((ROOT / "resources/asset-checksums.json").read_text())


def checksum(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url, target, size=None, sha256=None):
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and (size is None or target.stat().st_size == size):
        if not sha256 or checksum(target) == sha256:
            return target
    partial = target.with_suffix(target.suffix + ".partial")
    start = partial.stat().st_size if partial.exists() else 0
    if size is not None and start == size and (not sha256 or checksum(partial) == sha256):
        partial.replace(target)
        return target
    if size is not None and start >= size:
        partial.unlink()
        start = 0
    request = urllib.request.Request(url, headers={"Range": f"bytes={start}-"} if start else {})
    print(f"Downloading {target.name}…", flush=True)
    with urllib.request.urlopen(request, timeout=120) as response:
        mode = "ab" if start and response.status == 206 else "wb"
        with partial.open(mode) as out:
            shutil.copyfileobj(response, out, 1024 * 1024)
    if size is not None and partial.stat().st_size != size:
        raise ValueError(f"Incomplete download: {target}")
    if sha256 and checksum(partial) != sha256:
        partial.unlink()
        raise ValueError(f"Checksum mismatch: {target}")
    partial.replace(target)
    print(f"Ready: {target.name}", flush=True)
    return target


def install_models():
    api = "https://huggingface.co/api/models/lj1995/GPT-SoVITS"
    revision = "8f8857563c040d542de108a2c18b0425abd6c9c5"
    tree = json.load(urllib.request.urlopen(f"{api}/tree/{revision}?recursive=true&limit=1000", timeout=60))
    selected = [x for x in tree if x["path"].startswith(("chinese-hubert-base/", "chinese-roberta-wwm-ext-large/"))
                or x["path"] in ["s1v3.ckpt", "v2Pro/s2Gv2ProPlus.pth", "sv/pretrained_eres2netv2w24s4ep4.ckpt",
                                    "v2Pro/s2Dv2ProPlus.pth"]]
    def get(x):
        path = x["path"]
        checksum = x.get("lfs", {}).get("oid")
        download(f"https://huggingface.co/lj1995/GPT-SoVITS/resolve/{revision}/{urllib.parse.quote(path)}", MODELS / path, x["size"], checksum)
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(get, [x for x in selected if x["type"] == "file"]))
    (RUNTIME / "model-manifest.json").write_text(json.dumps({"revision": revision, "files": selected}, indent=2))
    # This tokenizer file is absent from the upstream model mirror.
    download("https://huggingface.co/hfl/chinese-roberta-wwm-ext-large/resolve/main/vocab.txt", MODELS / "chinese-roberta-wwm-ext-large/vocab.txt", sha256=CHECKSUMS["vocab.txt"])
    download("https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.bin", MODELS / "fast_langdetect/lid.176.bin", sha256=CHECKSUMS["lid.176.bin"])
    g2pw = GSV / "GPT_SoVITS/text/G2PWModel"
    if not (g2pw / "g2pW.onnx").exists():
        archive = download("https://huggingface.co/XXXXRT/GPT-SoVITS-Pretrained/resolve/main/G2PWModel.zip", RUNTIME / "downloads/G2PWModel.zip", sha256=CHECKSUMS["G2PWModel.zip"])
        with zipfile.ZipFile(archive) as z:
            # Refuse archive traversal, including symlinks.
            base = (GSV / "GPT_SoVITS/text").resolve()
            for item in z.infolist():
                if not (base / item.filename).resolve().is_relative_to(base):
                    raise ValueError("Unsafe archive path")
                if (item.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError("Archive contains a symlink")
            z.extractall(base)
    import nltk
    for name in ["averaged_perceptron_tagger", "averaged_perceptron_tagger_eng", "cmudict"]:
        if not nltk.download(name, download_dir=str(RUNTIME / "nltk_data")):
            raise RuntimeError(f"Could not download NLTK resource {name}")
    import pyopenjtalk
    pyopenjtalk.g2p("こんにちは。")


def install_voices(include_jsut=False):
    """Filled from curated, transcribed corpus clips in starter-sources.json."""
    sources = json.loads((ROOT / "resources/starter-sources.json").read_text())
    profiles = []
    for item in sources:
        if item.get("optional") and not include_jsut:
            continue
        target = RUNTIME / "voices" / (item["id"] + ".wav")
        raw = RUNTIME / "downloads" / item["filename"]
        if not raw.exists() or checksum(raw) != item["sha256"]:
            url = item.get("url")
            if "dataset" in item:
                query = urllib.parse.urlencode(dict(dataset=item["dataset"], config="default", split=item["split"], offset=item["row"], length=1))
                row = json.load(urllib.request.urlopen("https://datasets-server.huggingface.co/rows?" + query, timeout=60))["rows"][0]["row"]
                transcript = row.get("normalized_text", row.get("transcription", row.get("text")))
                if transcript != item["transcript"]:
                    raise ValueError(f"Dataset row changed for {item['id']}; refusing a mismatched reference transcript")
                url = row["audio"][0]["src"]
            download(url, raw, sha256=item["sha256"])
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(raw),
                            "-ac", "1", "-ar", "32000", "-c:a", "pcm_s16le", str(target)], check=True)
        import soundfile as sf
        info = sf.info(target)
        if not 3 <= info.duration <= 10:
            raise ValueError(f"Reference {item['id']} must be 3–10 seconds, got {info.duration:.2f}")
        profiles.append({"id": item["id"], "name": item["name"], "referencePath": str(target),
                         "transcript": item["transcript"], "language": item["language"],
                         "modelVersion": "v2ProPlus", "speed": 1.0, "source": item["source"],
                         "license": item["license"]})
    # Keep an explicitly installed optional voice on later default repair runs.
    manifest = RUNTIME / "starter-voices.json"
    if manifest.exists() and not include_jsut:
        previous = json.loads(manifest.read_text())
        profiles += [v for v in previous if v["id"] == "starter-ja" and Path(v["referencePath"]).is_file()]
    temporary = manifest.with_suffix(".json.partial")
    temporary.write_text(json.dumps(profiles, indent=2, ensure_ascii=False))
    temporary.replace(manifest)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voices-only", action="store_true")
    parser.add_argument("--include-jsut", action="store_true", help="Opt into JSUT personal/non-commercial research terms; see THIRD_PARTY.md")
    args = parser.parse_args()
    if not args.voices_only:
        install_models()
    install_voices(include_jsut=args.include_jsut)

