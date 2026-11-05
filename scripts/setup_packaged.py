#!/usr/bin/env python3
"""First-run setup for the packaged app. Uses only its embedded Python runtime."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

SOURCE = Path(__file__).resolve().parents[1]


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    partial = path.with_suffix('.json.partial')
    partial.write_text(json.dumps(value, indent=2) + '\n')
    partial.replace(path)


@contextmanager
def setup_lock(runtime):
    # The OS releases this lock after a crash/quit; no stale directory blocks retry.
    runtime.mkdir(parents=True, exist_ok=True)
    with (runtime / '.packaged-setup.lock').open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError('Setup is already running in another app window.') from exc
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def extract_source(archive, target):
    """Only ordinary files/directories below GPT-SoVITS/ are accepted."""
    with tarfile.open(archive) as source:
        for member in source:
            path = Path(member.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'GPT-SoVITS':
                raise ValueError('Unsafe upstream source archive path')
            destination = target / path
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                destination.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as data, destination.open('wb') as output:
                    shutil.copyfileobj(data, output)
                destination.chmod(member.mode & 0o755)
            else:
                raise ValueError('Upstream source archive contains a link or special file')


def prepare_upstream(source, runtime, manifest):
    archive = source / 'upstream.tar.gz'
    if sha256(archive) != manifest['upstreamSHA256']:
        raise ValueError('Bundled speech source is damaged. Reinstall the app.')
    versions = runtime / 'upstreams'
    versions.mkdir(exist_ok=True)
    version = versions / manifest['upstream']
    if not version.is_dir():
        with tempfile.TemporaryDirectory(prefix='.extract-', dir=versions) as temporary:
            stage = Path(temporary)
            extract_source(archive, stage)
            # Keep large downloaded weights separate from versioned source code.
            models = stage / 'GPT-SoVITS/GPT_SoVITS/pretrained_models'
            if models.exists():
                shutil.rmtree(models)
            models.parent.mkdir(parents=True, exist_ok=True)
            (runtime / 'models').mkdir(exist_ok=True)
            models.symlink_to('../../../models', target_is_directory=True)
            (stage / 'GPT-SoVITS').replace(version)
    current = runtime / 'GPT-SoVITS'
    if current.exists() and not current.is_symlink():
        raise RuntimeError('Managed speech source has an unexpected layout. Keep your data and reinstall the app.')
    temporary_link = runtime / '.upstream-link'
    temporary_link.unlink(missing_ok=True)
    temporary_link.symlink_to(Path('upstreams') / manifest['upstream'], target_is_directory=True)
    temporary_link.replace(current)


def install_ffmpeg(runtime, spec, download):
    binary = runtime / 'bin/ffmpeg'
    receipt = runtime / 'ffmpeg-source.json'
    if binary.is_file() and receipt.is_file():
        previous = json.loads(receipt.read_text())
        if previous.get('wheelSHA256') == spec['sha256'] and sha256(binary) == previous.get('binarySHA256'):
            return
    wheel = download(spec['url'], runtime / 'downloads' / spec['filename'], spec['size'], spec['sha256'])
    with zipfile.ZipFile(wheel) as package:
        names = [name for name in package.namelist() if name.startswith('imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-') and not name.endswith('/')]
        if len(names) != 1:
            raise ValueError('FFmpeg package has an unexpected layout')
        binary.parent.mkdir(exist_ok=True)
        temporary = binary.with_suffix('.partial')
        with package.open(names[0]) as data, temporary.open('wb') as output:
            shutil.copyfileobj(data, output)
        temporary.chmod(0o755)
        temporary.replace(binary)
        # Retain the wheel's notices beside the locally downloaded executable.
        notices = runtime / 'licenses/imageio-ffmpeg'
        notices.mkdir(parents=True, exist_ok=True)
        for name in package.namelist():
            if name.endswith('/'):
                continue
            if name.endswith(('/METADATA', '/LICENSE', '/LICENSE.txt', '/LICENSE.md', '/README.md')):
                (notices / Path(name).name).write_bytes(package.read(name))
    write_json(receipt, {'wheelSHA256': spec['sha256'], 'binarySHA256': sha256(binary), 'url': spec['url']})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--include-jsut', action='store_true')
    args = parser.parse_args()
    runtime = args.root.resolve() / 'runtime'
    with setup_lock(runtime):
        if shutil.disk_usage(runtime).free < 10 * 1024**3:
            raise RuntimeError('Setup needs at least 10 GB of free disk space. Free some space and retry.')
        manifest = json.loads((SOURCE / 'runtime-manifest.json').read_text())
        distribution = json.loads((SOURCE / 'resources/runtime-distribution.json').read_text())
        os.environ['LOCALSPEAK_ROOT'] = str(args.root.resolve())
        os.environ['PATH'] = str(runtime / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin'
        os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
        import download_assets as assets
        print('Step 1 of 4 · Preparing bundled speech code', flush=True)
        prepare_upstream(SOURCE, runtime, manifest)
        print('Step 2 of 4 · Downloading FFmpeg (21 MB)', flush=True)
        install_ffmpeg(runtime, distribution['ffmpeg'], assets.download)
        subprocess.run([str(runtime / 'bin/ffmpeg'), '-version'], check=True, stdout=subprocess.DEVNULL)
        print('Step 3 of 4 · Downloading and verifying speech models', flush=True)
        assets.install_models()
        print('Step 4 of 4 · Preparing example voices', flush=True)
        assets.install_voices(include_jsut=args.include_jsut)
        # This marker is written only after all setup phases succeed.
        write_json(runtime / 'setup-complete.json', {'runtimeID': manifest['runtimeID']})
        print('Setup complete. Loading the speech engine…', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'\nSetup failed: {exc}\nCheck your connection and disk space, then retry. Completed downloads are retained.', flush=True)
        raise SystemExit(1)
