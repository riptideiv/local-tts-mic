# Voice import and catalogue

Open **Voices**. **Installed** lists saved voices; **Catalogue** lists optional community profiles. **Add manually** retains the original reference/checkpoint editor.

## Catalogue

Choose **Review download…**, read the source/model card and terms, then **Download and import**. The entry supplies a matching checkpoint pair, supported architecture, reference clip, exact transcript, language, total size, immutable repository revision, and file hashes. Imported voices appear in the library without changing the selected broadcast voice. **Preview** is private and leaves that selection unchanged; **Use voice** selects it for future messages.

The initial catalogue contains three Japanese character profiles maintained by [lpkpaco](https://huggingface.co/lpkpaco/Bocchi-The-Rock-GPT-SoVITS-Models): Hitori Gotoh, Nijika Ichiji, and Ikuyo Kita. All use the author's v2ProPlus directories. Their reference clips were checked to be 6.18, 4.11, and 3.68 seconds. The model card declares **CC BY-NC-SA 4.0**; attribution, non-commercial, share-alike, and the author's notices are shown before download. Model-card licensing does not grant rights to underlying characters or performances. Files are downloaded from the author; no checkpoints or recordings are included in this repository or installer.

The catalogue is a small set of maintained manifests, not a search index or a claim that every Hub model works. Model metadata and reference duration are checked; inference quality depends on the particular model. See the author's card and listen to a private Preview before using a voice.

## Hugging Face URL

Click **Import…**, paste a public model URL or `owner/repository`, then **Inspect**. Repository, tree, blob, and resolve URLs are accepted. The importer resolves the revision once and downloads selected files from that immutable commit.

It lists `.ckpt`, `.pth`, and WAV/FLAC/MP3/M4A/AIFF audio files, reads the model card and license identifier, and detects available metadata. If a repository has several voices or epochs, choose the matching pair and reference. Fill in missing architecture, reference language, or transcript. For a reference-only profile, leave both checkpoints at **None** and choose **v2ProPlus**, the pretrained model.

No Python checkpoint is loaded during inspection or import. The importer verifies selected files against the Hub's SHA-256 or Git-blob hashes. It does not run repository scripts or install repository dependencies. Checkpoints are loaded only when synthesis uses the imported voice; PyTorch checkpoints can execute code, so only import sources you trust.

Private/gated repositories and account tokens are not supported. Download those models through their normal access flow, then import the folder. Source terms must still permit your use.

## Downloaded folder

Extract archives in Finder first, then choose **Import… → Choose folder…**. Select the voice's folder, not an entire model library. The importer detects checkpoints, reference audio, matching `.lab`/`.txt` sidecars, and standard GPT-SoVITS `.list` transcripts (`path|speaker|language|text`). If matching audio basenames are ambiguous, it asks for the transcript instead of guessing.

A folder or repository may include this optional root-level `local-tts-mic.voice.json` (also accepted as `voice.json`):

```json
{
  "name": "My voice",
  "modelVersion": "v2ProPlus",
  "language": "en",
  "gpt": "checkpoints/model.ckpt",
  "sovits": "checkpoints/model.pth",
  "reference": "reference.wav",
  "transcript": "The exact words in the reference recording.",
  "license": "The model's actual license or usage terms."
}
```

Paths are relative to the folder/repository. References must be 3–10 seconds. Supported reference languages are English, Mandarin, and Japanese. Architectures v1, v3, and v4 are unsupported; a creator's unrelated release number in a filename is not treated as the architecture.

## Storage and cancellation

Successful imports copy checkpoints and references into `~/Library/Application Support/Local Speak/voice-library/`. Saved profiles keep their own reference copy in `references/`. Moving or deleting the original download folder does not break an imported voice. The imported folder retains the model card, provenance, and a reusable `local-tts-mic.voice.json` manifest; no data is uploaded.

Canceling or failing an import removes its temporary staging files and adds no profile. Retry starts a new import; partial checkpoint downloads are not retained. Removing a profile does not erase its checkpoint files, which another profile may still reference. Back up profiles and models before manually cleaning the voice library.

Other discovery sources: [Hugging Face GPT-SoVITS search](https://huggingface.co/models?search=GPT-SoVITS) and [AI Hobbyist](https://www.ai-hobbyist.com/forum-138-1.html). Many listings contain unsupported versions, missing reference metadata, or restrictive terms; review them before importing.

## Validation

The native catalogue review and a real Hitori Gotoh download/import were tested against the pinned Hub revision. All three files passed integrity checks, the imported profile survived an app restart, and the existing broadcast selection stayed unchanged. Changing a repository URL clears its previous inspection, terms acknowledgement, and catalogue selection. Curated reviews hide file details by default; generic imports expose the choices.

The Hitori checkpoint data was loaded through PyTorch’s restricted weights-only loader (using a data-only stand-in for its HParams record), converted to plain tensor/config data, and tested through the actual CPU worker. Japanese synthesis produced 2.62 seconds of finite, non-silent audio, with first audio at 2.75 seconds in that run. This validates that pair’s data with the current engine; it is not a quality or speed guarantee for every language or catalogue entry.

The native test suite covers folder/path safety, transcript matching, immutable Hub inspection, URL escaping, hashes, short references, incomplete pairs, architecture headers, cancellation cleanup, reusable manifests, and private previews preserving the broadcast selection. No community voice files were committed or uploaded.
