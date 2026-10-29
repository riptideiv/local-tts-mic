"""Packaged setup keeps downloaded assets separate and rejects unsafe archives."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import zipfile
import pytest

spec = importlib.util.spec_from_file_location('setup_packaged', Path(__file__).resolve().parents[1] / 'scripts/setup_packaged.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


def source_tar(path, entries):
    with tarfile.open(path, 'w:gz') as archive:
        for name, data, kind in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.mode = 0o644
            if kind == tarfile.REGTYPE:
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            else:
                info.linkname = '/tmp/outside'
                archive.addfile(info)


@pytest.mark.parametrize('name,kind', [('../outside', tarfile.REGTYPE), ('/outside', tarfile.REGTYPE), ('GPT-SoVITS/link', tarfile.SYMTYPE), ('GPT-SoVITS/link', tarfile.LNKTYPE), ('GPT-SoVITS/fifo', tarfile.FIFOTYPE)])
def test_upstream_archive_rejects_unsafe_entries(tmp_path, name, kind):
    archive = tmp_path / 'source.tar.gz'
    source_tar(archive, [(name, b'bad', kind)])
    with pytest.raises(ValueError):
        setup.extract_source(archive, tmp_path / 'target')
    assert not (tmp_path / 'outside').exists()


def test_versioned_upstream_retains_weights_and_repairs_after_retry(tmp_path):
    source, runtime = tmp_path / 'app', tmp_path / 'user/runtime'
    source.mkdir(); runtime.mkdir(parents=True)
    archive = source / 'upstream.tar.gz'
    source_tar(archive, [('GPT-SoVITS/GPT_SoVITS/module.py', b'code', tarfile.REGTYPE)])
    manifest = {'upstream': 'revision1', 'upstreamSHA256': setup.sha256(archive)}
    setup.prepare_upstream(source, runtime, manifest)
    assert (runtime / 'GPT-SoVITS/GPT_SoVITS/module.py').read_bytes() == b'code'
    (runtime / 'models/voice.pth').write_bytes(b'weights')
    setup.prepare_upstream(source, runtime, manifest)
    assert (runtime / 'GPT-SoVITS/GPT_SoVITS/pretrained_models/voice.pth').read_bytes() == b'weights'
    # A code update shares the weights and retains the previous source version.
    setup.prepare_upstream(source, runtime, dict(manifest, upstream='revision2'))
    assert (runtime / 'upstreams/revision1').is_dir()
    assert (runtime / 'GPT-SoVITS/GPT_SoVITS/pretrained_models/voice.pth').read_bytes() == b'weights'
    assert not (runtime / 'setup-complete.json').exists()


def test_damaged_bundled_source_never_switches_upstream(tmp_path):
    runtime = tmp_path / 'runtime'; runtime.mkdir()
    (tmp_path / 'upstream.tar.gz').write_bytes(b'damaged')
    with pytest.raises(ValueError, match='damaged'):
        setup.prepare_upstream(tmp_path, runtime, {'upstream': 'x', 'upstreamSHA256': 'bad'})
    assert not (runtime / 'GPT-SoVITS').exists()


def test_setup_lock_excludes_other_instances_and_releases_on_failure(tmp_path):
    with pytest.raises(ValueError):
        with setup.setup_lock(tmp_path):
            with pytest.raises(RuntimeError, match='already running'):
                with setup.setup_lock(tmp_path): pass
            raise ValueError('interrupted')
    with setup.setup_lock(tmp_path): pass


def test_ffmpeg_download_is_verified_and_reused_then_repairs_corruption(tmp_path):
    wheel = tmp_path / 'ffmpeg.whl'
    with zipfile.ZipFile(wheel, 'w') as archive:
        archive.writestr('imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1', b'executable')
        archive.writestr('imageio_ffmpeg-0.6.0.dist-info/LICENSE', b'license')
    downloads = []
    def download(url, destination, size, checksum):
        downloads.append(url)
        assert size == wheel.stat().st_size
        assert setup.sha256(wheel) == checksum
        return wheel
    config = {'url': 'https://example.invalid/ffmpeg.whl', 'filename': wheel.name, 'size': wheel.stat().st_size, 'sha256': setup.sha256(wheel)}
    setup.install_ffmpeg(tmp_path, config, download)
    setup.install_ffmpeg(tmp_path, config, download)
    assert downloads == [config['url']]
    assert (tmp_path / 'bin/ffmpeg').stat().st_mode & 0o111
    assert (tmp_path / 'licenses/imageio-ffmpeg/LICENSE').read_bytes() == b'license'
    (tmp_path / 'bin/ffmpeg').write_bytes(b'corrupted')
    setup.install_ffmpeg(tmp_path, config, download)
    assert len(downloads) == 2
    assert (tmp_path / 'bin/ffmpeg').read_bytes() == b'executable'


def test_setup_completion_marker_requires_all_downloads(tmp_path, monkeypatch):
    import sys
    import types
    for key in ['LOCALSPEAK_ROOT', 'PATH', 'PYTHONDONTWRITEBYTECODE']:
        monkeypatch.setenv(key, setup.os.environ.get(key, ''))
    source, root = tmp_path / 'app', tmp_path / 'user'
    (source / 'resources').mkdir(parents=True)
    (source / 'runtime-manifest.json').write_text(json.dumps({'runtimeID': 'expected'}))
    (source / 'resources/runtime-distribution.json').write_text(json.dumps({'ffmpeg': {}}))
    monkeypatch.setattr(setup, 'SOURCE', source)
    monkeypatch.setattr(sys, 'argv', ['setup', '--root', str(root)])
    monkeypatch.setattr(setup, 'prepare_upstream', lambda *a: None)
    monkeypatch.setattr(setup, 'install_ffmpeg', lambda *a: None)
    monkeypatch.setattr(setup.subprocess, 'run', lambda *a, **k: None)
    monkeypatch.setattr(setup.shutil, 'disk_usage', lambda *a: types.SimpleNamespace(free=20 * 1024**3))
    def fail():
        (root / 'runtime/completed-download').write_text('retained')
        raise OSError('network interrupted')
    assets = types.SimpleNamespace(download=None, install_models=fail, install_voices=lambda **k: None)
    monkeypatch.setitem(sys.modules, 'download_assets', assets)
    with pytest.raises(OSError, match='interrupted'):
        setup.main()
    assert not (root / 'runtime/setup-complete.json').exists()
    assets.install_models = lambda: None
    setup.main()
    assert json.loads((root / 'runtime/setup-complete.json').read_text()) == {'runtimeID': 'expected'}
    assert (root / 'runtime/completed-download').read_text() == 'retained'
    assert not (source / 'runtime').exists()


def test_installer_enforces_os_volume_check_and_closes_running_app():
    spec = importlib.util.spec_from_file_location('package_macos', Path(__file__).resolve().parents[1] / 'scripts/package-macos.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    distribution = builder.make_distribution('1.1.0')
    # OS ranges at the root are ignored by Installer; they belong in volume-check.
    assert distribution.find('allowed-os-versions') is None
    assert distribution.find('volume-check/allowed-os-versions/os-version').get('min') == '15.0'
    assert distribution.find('options').get('hostArchitectures') == 'arm64'
    close = distribution.find("pkg-ref/must-close/app")
    assert close.get('id') == 'local.localspeak.app'
    packages = {ref.get('id'): ref.text for ref in distribution.findall('pkg-ref') if ref.text}
    assert packages == {'local.localspeak.app.installer': 'app.pkg', 'local.localspeak.mic.installer': 'driver.pkg'}
