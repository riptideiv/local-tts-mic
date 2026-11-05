#!/usr/bin/env python3
"""Persistent GPT-SoVITS worker. Stdout is exclusively the JSON-line protocol."""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import sys
import threading
import time
import traceback

from protocol import validate_job

# Native libraries (notably Open JTalk) also write to fd 1 directly.
# Preserve a separate protocol descriptor before redirecting *all* stdout.
PROTOCOL = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
sys.stdout = sys.stderr
WRITE_LOCK = threading.Lock()


def emit(kind, **fields):
    with WRITE_LOCK:
        PROTOCOL.write(json.dumps({"type": kind, **fields}, ensure_ascii=False) + "\n")
        PROTOCOL.flush()


class Worker:
    def __init__(self, root, device, output):
        self.root, self.device, self.output = root, device, output
        self.commands = queue.Queue()
        self.cancelled = set()
        self.cancel_lock = threading.Lock()
        self.active_id = None
        self.pending_ids = set()
        self.pipeline = None
        self.loaded_pair = None

    def reader(self):
        for line in sys.stdin:
            try:
                command = json.loads(line)
                if command.get("type") == "cancel":
                    with self.cancel_lock:
                        job_id = command.get("id")
                        if job_id in self.pending_ids:
                            self.cancelled.add(job_id)
                            if job_id == self.active_id and self.pipeline:
                                self.pipeline.stop()
                elif command.get("type") == "shutdown":
                    os._exit(0)
                else:
                    with self.cancel_lock:
                        self.pending_ids.add(command.get("id"))
                    self.commands.put(command)
            except Exception as exc:
                emit("error", message=f"Invalid worker command: {exc}")
        os._exit(0)  # Parent exited; do not leave an orphan model process.

    def load(self):
        emit("status", message=f"Loading GPT-SoVITS on {self.device.upper()}…")
        os.chdir(self.root / "runtime/GPT-SoVITS")
        sys.path[:0] = [os.getcwd(), str(Path.cwd() / "GPT_SoVITS")]
        os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        os.environ["NLTK_DATA"] = str(self.root / "runtime/nltk_data")
        os.environ["TOKENIZERS_PARALLELISM"] = "false"
        os.environ["MPLCONFIGDIR"] = str(self.root / "runtime/cache/matplotlib")
        os.environ["NUMBA_CACHE_DIR"] = str(self.root / "runtime/cache/numba")
        # All runtime assets have already been downloaded by setup.
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        import torch
        torch.set_num_threads(6)
        from GPT_SoVITS.TTS_infer_pack.TTS import TTS, TTS_Config
        self.TTS_Config = TTS_Config
        config = dict(TTS_Config.default_configs["v2ProPlus"])
        config.update(device=self.device, is_half=False)
        self.pipeline = TTS(TTS_Config({"custom": config}))
        self.loaded_pair = (config["t2s_weights_path"], config["vits_weights_path"])
        emit("ready", device=self.device, model="v2ProPlus")

    def is_cancelled(self, job_id):
        with self.cancel_lock:
            return job_id in self.cancelled

    def select_weights(self, voice):
        defaults = self.TTS_Config.default_configs[voice["modelVersion"]]
        pair = (voice.get("gptPath") or defaults["t2s_weights_path"],
                voice.get("sovitsPath") or defaults["vits_weights_path"])
        if pair != self.loaded_pair:
            self.loaded_pair = None  # A failed partial load must never be reused.
            # Semantic tokens, reference spectra, and phoneme IDs depend on the
            # weights and symbol inventory, even when the reference path is unchanged.
            self.pipeline.prompt_cache = {
                "ref_audio_path": None, "prompt_semantic": None, "refer_spec": [],
                "prompt_text": None, "prompt_lang": None, "phones": None,
                "bert_features": None, "norm_text": None, "aux_ref_audio_paths": [],
            }
            # SoVITS establishes the actual architecture and language inventory.
            self.pipeline.init_vits_weights(pair[1])
            actual = self.pipeline.configs.version
            if actual != voice["modelVersion"]:
                raise ValueError(f"Checkpoint version is {actual}; set this voice's model version accordingly.")
            self.pipeline.init_t2s_weights(pair[0])
            self.loaded_pair = pair
        elif self.pipeline.configs.version != voice["modelVersion"]:
            raise ValueError(f"Checkpoint version is {self.pipeline.configs.version}; set this voice's model version accordingly.")

    def synthesize(self, command):
        import numpy as np
        import soundfile as sf
        started = time.monotonic()
        job_id = command.get("id", "")
        text, voice, speed = validate_job(command)
        if self.is_cancelled(job_id):
            emit("cancelled", id=job_id)
            return
        info = sf.info(voice["referencePath"])
        if not 3 <= info.duration <= 10:
            raise ValueError("Use a clear reference clip between 3 and 10 seconds.")
        self.select_weights(voice)
        inputs = dict(text=text, text_lang=command["language"], ref_audio_path=voice["referencePath"],
                      prompt_text=voice["transcript"], prompt_lang=voice["language"],
                      speed_factor=speed, text_split_method="cut5", batch_size=1, split_bucket=False,
                      return_fragment=True, streaming_mode=False, fragment_interval=0.15,
                      seed=42, top_k=15, top_p=1.0, temperature=1.0, repetition_penalty=1.35,
                      parallel_infer=True, use_cuda_graph=False, use_flash_attention=False)
        chunks = []
        first_audio = None
        sample_rate = 32000
        emit("started", id=job_id)
        for index, (sample_rate, audio) in enumerate(self.pipeline.run(inputs)):
            if self.is_cancelled(job_id):
                break
            if not len(audio):
                continue
            chunks.append(audio)
            path = self.output / f"{job_id}-{index}.wav"
            sf.write(path, audio, sample_rate, subtype="PCM_16")
            if first_audio is None:
                first_audio = time.monotonic() - started
            emit("audio", id=job_id, path=str(path), seconds=len(audio) / sample_rate,
                 firstAudio=first_audio, sampleRate=sample_rate)
        if self.is_cancelled(job_id):
            emit("cancelled", id=job_id)
        elif chunks:
            path = self.output / f"{job_id}.wav"
            samples = np.concatenate(chunks)
            sf.write(path, samples, sample_rate, subtype="PCM_16")
            emit("complete", id=job_id, path=str(path), seconds=len(samples) / sample_rate,
                 elapsed=time.monotonic() - started, firstAudio=first_audio)
        else:
            raise RuntimeError("The model returned no speech. Try a shorter sentence or another reference clip.")
        with self.cancel_lock:
            self.cancelled.discard(job_id)

    def run(self):
        threading.Thread(target=self.reader, daemon=True).start()
        self.load()
        while True:
            command = self.commands.get()
            try:
                with self.cancel_lock:
                    self.active_id = command.get("id")
                if command.get("type") != "synthesize":
                    raise ValueError("Unknown worker command")
                self.synthesize(command)
            except Exception as exc:
                traceback.print_exc()
                emit("error", id=command.get("id", ""), message=str(exc))
            finally:
                with self.cancel_lock:
                    self.cancelled.discard(self.active_id)
                    self.pending_ids.discard(self.active_id)
                    self.active_id = None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--device", choices=["cpu", "mps"], default="cpu")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    try:
        Worker(args.root, args.device, args.output).run()
    except Exception as exc:
        traceback.print_exc()
        emit("fatal", message=str(exc))
        sys.exit(1)


if __name__ == "__main__":
    main()
