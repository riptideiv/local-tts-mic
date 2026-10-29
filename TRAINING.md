# Train your custom voice later

The starter voices work with reference audio, so you can use Local TTS Mic immediately without training. For a new voice, first try adding a clean 3–10 second recording and its exact transcript.

## Fine-tune locally

1. In **Voices**, click **Open training tools**. Local TTS Mic stops speech, releases its inference worker, and opens the upstream GPT-SoVITS WebUI at `http://127.0.0.1:9874`.
2. Use the **v2ProPlus** version selected by this app's training adapter. Its base generator, discriminator, GPT, HuBERT, BERT, and Chinese pronunciation models are already installed.
3. Prepare clear recordings from one speaker. A few minutes of varied, accurately transcribed speech is a better starting point than a single repeated sentence. Remove music, reverberation, clipped audio, and long silence.
4. In the dataset tools, slice recordings, optionally transcribe them, then proofread every line. English/Japanese ASR can download a Faster Whisper model on first use. Manual transcripts also work; the app's optional validation model is under `runtime/asr/small` if present.
5. Prepare the dataset and train the SoVITS and GPT stages using **CPU**, small batches, and full precision. GPU training on Macs is not recommended by upstream because of quality issues. Leave the tool open while training; closing it terminates its child jobs.
6. Keep the resulting GPT `.ckpt` and SoVITS `.pth` checkpoint files. Upstream places models in its corresponding versioned weight folders; the training UI shows the saved paths. Experiments and datasets live under `runtime/GPT-SoVITS/logs/`.
7. Click **Close tools and resume speech** in Local TTS Mic. Add a voice with the matching model version, both checkpoint files, a clean 3–10 second reference, and the exact reference transcript.
8. Use **Preview** before broadcasting, then test it through the virtual microphone.

The upstream annotation `.list` format is:

```text
/absolute/path/to/clip.wav|speaker_name|en|The words in this clip.
/absolute/path/to/中文.wav|speaker_name|zh|这段录音里的文字。
/absolute/path/to/日本語.wav|speaker_name|ja|この録音の文章です。
```

Choose `en`, `zh`, or `ja` to match each recording's language. The reference clip used at inference still needs its own matching transcript after fine-tuning.

CPU training can take a long time. This project provides the working upstream training interface and model import; it does not train a custom voice automatically.

Upstream: [GPT-SoVITS](https://github.com/RVC-Boss/GPT-SoVITS), [Mac installation/training note](https://github.com/RVC-Boss/GPT-SoVITS#macos).

