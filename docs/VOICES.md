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

Paths are relative to the folder/repository. References must be 3–10 seconds. Supported reference languages are English, Mandarin, and Japanese. Imported checkpoint pairs support v1, v2, v2Pro, and v2ProPlus. Architectures v3 and v4 are unsupported; a creator's unrelated release number in a filename is not treated as the architecture.

## v1 checkpoints

Choose **v1** in the import sheet or voice editor and supply both the GPT `.ckpt` and SoVITS `.pth` files. The installed pretrained model remains v2ProPlus; v1 needs an imported pair and does not download another base model. English, Mandarin, Japanese, and Auto text use the engine's v1 symbol inventory. Version changes clear cached reference audio features and prompt phonemes before synthesis.

Legacy v1 checkpoints often have a normal ZIP header and unversioned folder names, so the importer cannot safely identify their architecture from filenames alone. Select v1 explicitly. The worker confirms the SoVITS architecture from the loaded checkpoint and reports a version mismatch before inference if the selection is wrong. Numbered `00`/`01` headers identify v1/v2 during import; v3/v4/v5 headers remain unsupported.

For [MomoyamaSawa/GPT-SoVITS_KusanagiNene](https://huggingface.co/MomoyamaSawa/GPT-SoVITS_KusanagiNene), the author's recommended pair is:

- GPT: `GPT_weights/nene30-e15.ckpt`
- SoVITS: `SoVITS_weights/nene30_e8_s328.pth`
- Model: **v1**; reference language: **Japanese**.

Use a clear 3–10 second recording of the same voice and its exact transcript. The model repository's README audio files are generated demonstrations, not labelled original reference recordings. The author links a separate [recording dataset and `nene_org.txt` labels](https://huggingface.co/datasets/MomoyamaSawa/Voice-KusanagiNene/tree/main). Choose your permitted recording through **Use my own clip…** and enter its transcript. Review the author's model/dataset terms and underlying voice rights before using it.

## Storage and cancellation

Successful imports copy checkpoints and references into `~/Library/Application Support/Local Speak/voice-library/`. Saved profiles keep their own reference copy in `references/`. Moving or deleting the original download folder does not break an imported voice. The imported folder retains the model card, provenance, and a reusable `local-tts-mic.voice.json` manifest; no data is uploaded.

Canceling or failing an import removes its temporary staging files and adds no profile. Retry starts a new import; partial checkpoint downloads are not retained. Removing a profile does not erase its checkpoint files, which another profile may still reference. Back up profiles and models before manually cleaning the voice library.

Other discovery sources: [Hugging Face GPT-SoVITS search](https://huggingface.co/models?search=GPT-SoVITS) and [AI Hobbyist](https://www.ai-hobbyist.com/forum-138-1.html). Many listings contain unsupported versions, missing reference metadata, or restrictive terms; review them before importing.

## Validation

The native catalogue review and a real Hitori Gotoh download/import were tested against the pinned Hub revision. All three files passed integrity checks, the imported profile survived an app restart, and the existing broadcast selection stayed unchanged. Changing a repository URL clears its previous inspection, terms acknowledgement, and catalogue selection. Curated reviews hide file details by default; generic imports expose the choices.

The Hitori checkpoint data was loaded through PyTorch’s restricted weights-only loader (using a data-only stand-in for its HParams record), converted to plain tensor/config data, and tested through the actual CPU worker. Japanese synthesis produced 2.62 seconds of finite, non-silent audio, with first audio at 2.75 seconds in that run. This validates that pair’s data with the current engine; it is not a quality or speed guarantee for every language or catalogue entry.

The native test suite covers folder/path safety, transcript matching, immutable Hub inspection, URL escaping, hashes, short references, incomplete pairs, architecture headers, cancellation cleanup, reusable manifests, and private previews preserving the broadcast selection. No community voice files were committed or uploaded.

### v1 validation

The Nene pair above was downloaded from model revision `4dd5b92a0c2f2a8290eaa8c3301e88db2f86fc3b` and verified against the Hub's SHA-256 hashes. A restricted weights-only reload with a data-only HParams stand-in confirmed the SoVITS text embedding has 322 symbols (v1). No original checkpoint pickle code was executed during this test.

The reference was `nene/area1_043_001.mp3` from dataset revision `8c2236bde08008b9290f4ea9b543a8028845c1f7`, converted to a 6.01-second mono WAV and paired with its original label. The real CPU worker produced 4.18 seconds of finite, non-silent Japanese speech, with first audio at 2.57 seconds in that run. Switching v1 → v2ProPlus → v1 with the same reference/transcript succeeded; an incorrectly labelled pair was rejected and a subsequent v1 request recovered. These are single-machine checks, not guarantees for every v1 model or MPS.

The native app also imported a folder containing this restricted checkpoint data and completed a private Japanese preview with first audio at 2.4 seconds, while preserving the selected broadcast voice. Model-free regression tests cover v1 protocol validation, required checkpoint pairs, local-folder import, version headers, reference-cache invalidation across versions, and failed-load recovery. No Nene checkpoints, recordings, or generated samples are bundled or committed.
