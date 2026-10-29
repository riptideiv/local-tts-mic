"""Launch the upstream training UI bound to localhost, with child cleanup."""
from pathlib import Path
import os
import runpy
import signal
import sys

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT / "runtime/GPT-SoVITS")
sys.path[:0] = [os.getcwd(), str(Path.cwd() / "GPT_SoVITS")]
os.environ.update(GRADIO_ANALYTICS_ENABLED="False", is_share="False", is_half="False", CUDA_VISIBLE_DEVICES="")
os.environ["NLTK_DATA"] = str(ROOT / "runtime/nltk_data")
os.environ["MPLCONFIGDIR"] = str(ROOT / "runtime/cache/matplotlib")

# Upstream hard-codes 0.0.0.0. Override the public launch API rather than edit vendor files.
import gradio as gr
launch = gr.Blocks.launch


def local_launch(self, *args, **kwargs):
    kwargs.update(server_name="127.0.0.1", share=False, inbrowser=False)
    return launch(self, *args, **kwargs)


gr.Blocks.launch = local_launch


def shutdown(*_):
    import psutil
    children = psutil.Process().children(recursive=True)
    for process in reversed(children):
        try:
            process.terminate()
        except psutil.NoSuchProcess:
            pass
    psutil.wait_procs(children, timeout=3)
    sys.exit(0)


signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)
# Match the pretrained weights installed by this app. The pinned upstream script
# otherwise defaults to v2Pro, whose additional weights are not needed here.
source = Path("webui.py").read_text()
old = 'os.environ["version"] = version = "v2Pro"'
assert old in source, "Upstream startup changed; update the training adapter."
source = source.replace(old, 'os.environ["version"] = version = "v2ProPlus"', 1)
exec(compile(source, "webui.py", "exec"), {"__name__": "__main__", "__file__": str(Path("webui.py").resolve())})
