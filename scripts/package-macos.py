#!/usr/bin/env python3
"""Build a relocatable Apple Silicon app and app+microphone Installer package.

Development tools are required on the builder, never on the recipient's Mac.
Unsigned packages must be labelled as previews; --sign requires Developer ID identities.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/distribution'
CACHE = ROOT / 'build/package-cache'
MIN_MACOS = json.loads((ROOT / 'resources/runtime-distribution.json').read_text())['macos']


def run(*args, **kwargs):
    print('+', *map(str, args), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def prepare_python(config, uv):
    cache_key = hashlib.sha256((config['python'] + ':portable-v2:' + digest(ROOT / 'requirements.lock')).encode()).hexdigest()
    destination = CACHE / 'runtime/python'
    marker = destination.parent / 'complete.json'
    if marker.exists() and json.loads(marker.read_text()).get('key') == cache_key:
        return destination
    env = dict(os.environ, UV_PYTHON_INSTALL_DIR=str(CACHE / 'managed-python'), UV_CACHE_DIR=str(CACHE / 'uv-cache'))
    run(uv, 'python', 'install', config['python'], env=env)
    interpreter = subprocess.check_output([uv, 'python', 'find', '--managed-python', config['python']], env=env, text=True).strip()
    original = Path(interpreter).resolve().parents[1]
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(original, destination, symlinks=True)
    # Install into this standalone distribution, not the builder's Python or venv.
    run(uv, 'pip', 'sync', '--python', destination / 'bin/python3', '--break-system-packages', ROOT / 'requirements.lock', env=env)
    run(uv, 'pip', 'check', '--python', destination / 'bin/python3', env=env)
    # Open JTalk otherwise tries downloading its dictionary inside the signed app.
    run(destination / 'bin/python3', '-I', '-B', '-c', 'import pyopenjtalk; pyopenjtalk.g2p("こんにちは。")')
    relocate_python(destination, original)
    for cache in destination.rglob('__pycache__'):
        shutil.rmtree(cache)
    marker.write_text(json.dumps({'key': cache_key}))
    return destination


def source_archive(config):
    repo = ROOT / 'runtime/GPT-SoVITS'
    if not (repo / '.git').exists():
        repo = CACHE / 'upstream.git'
        if not repo.exists():
            run('git', 'init', '--bare', repo)
        run('git', '-C', repo, 'fetch', '--depth', '1', 'https://github.com/RVC-Boss/GPT-SoVITS.git', config['upstream'])
    run('git', '-C', repo, 'cat-file', '-e', config['upstream'] + '^{commit}')
    archive = CACHE / 'upstream.tar.gz'
    run('git', '-C', repo, 'archive', '--format=tar.gz', '--prefix=GPT-SoVITS/', '-o', archive, config['upstream'])
    return archive


def macho_files(app):
    magic = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
    for path in app.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream:
                if stream.read(4) in magic:
                    yield path


def relocate_python(destination, original):
    # uv rewrites the shared Python library's install name for its managed cache.
    # Remove those build-machine paths before sealing the portable runtime.
    for path in macho_files(destination):
        identifiers = subprocess.check_output(['otool', '-D', str(path)], text=True).splitlines()[1:]
        own_id = identifiers[0] if identifiers else None
        if own_id and own_id.startswith('/'):
            run('install_name_tool', '-id', '@rpath/' + path.name, path)
        dependencies = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
        for line in dependencies:
            if not line.startswith('\t'): continue
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith(str(original) + '/'):
                relative = Path(dependency).relative_to(original)
                target = destination / relative
                run('install_name_tool', '-change', dependency, '@loader_path/' + os.path.relpath(target, path.parent), path)
    # Console-script entry points use /usr/bin/env and the embedded bin directory.
    for path in (destination / 'bin').iterdir():
        if path.is_symlink() or not path.is_file(): continue
        with path.open('rb') as stream: header = stream.read(2)
        if header == b'#!':
            data = path.read_bytes()
            first, sep, rest = data.partition(b'\n')
            if b'python' in first:
                path.write_bytes(b'#!/usr/bin/env python3' + sep + rest)


def verify_relocation(app):
    for path in app.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(app.resolve()):
            raise RuntimeError(f'Non-portable symlink: {path}')
    for path in macho_files(app):
        metadata = subprocess.check_output(['otool', '-l', str(path)], text=True)
        versions = re.findall(r'\bminos (\d+(?:\.\d+)*)', metadata)
        versions += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+)*)', metadata)
        for version in versions:
            parts = tuple(map(int, version.split('.')))
            required = tuple(map(int, MIN_MACOS.split('.')))
            if parts + (0,) * (3 - len(parts)) > required + (0,) * (3 - len(required)):
                raise RuntimeError(f'{path} requires macOS {version}, newer than packaged minimum {MIN_MACOS}')
        output = subprocess.check_output(['otool', '-L', str(path)], text=True)
        for line in output.splitlines()[1:]:
            if not line.startswith('\t'): continue
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith('/') and not dependency.startswith(('/usr/lib/', '/System/Library/')):
                raise RuntimeError(f'Non-portable library dependency in {path}: {dependency}')
    python = app / 'Contents/Resources/LocalTTSMic/python/bin/python3'
    prefix = subprocess.check_output([python, '-I', '-B', '-c', 'import sys; print(sys.prefix)'], text=True).strip()
    if Path(prefix).resolve() != python.parent.parent.resolve():
        raise RuntimeError('Bundled Python points outside the app')


def sign_code(app, driver, identity):
    entitlements = ROOT / 'resources/packaging/python-entitlements.plist'
    for path in sorted(macho_files(app), key=lambda p: len(p.parts), reverse=True):
        args = ['codesign', '--force', '--sign', identity]
        if identity != '-':
            args += ['--timestamp', '--options', 'runtime']
            if path.name.startswith('python'):
                args += ['--entitlements', entitlements]
        run(*args, path)
    for framework in sorted(app.rglob('*.framework'), key=lambda p: len(p.parts), reverse=True):
        args = ['codesign', '--force', '--sign', identity]
        if identity != '-': args += ['--timestamp', '--options', 'runtime']
        run(*args, framework)
    for bundle in [driver, app]:
        args = ['codesign', '--force', '--sign', identity]
        if identity != '-': args += ['--timestamp', '--options', 'runtime']
        run(*args, bundle)
        run('codesign', '--verify', '--deep', '--strict', bundle)


def component(root, output, identifier, version, scripts=None):
    plist = output.with_suffix('.components.plist')
    run('pkgbuild', '--analyze', '--root', root, plist)
    values = plistlib.loads(plist.read_bytes())
    for value in values:
        value.update(BundleIsRelocatable=False, BundleHasStrictIdentifier=True, BundleOverwriteAction='upgrade')
    plist.write_bytes(plistlib.dumps(values))
    args = ['pkgbuild', '--root', root, '--component-plist', plist, '--identifier', identifier, '--version', version, '--install-location', '/', '--ownership', 'recommended']
    if scripts: args += ['--scripts', scripts]
    run(*args, output)


def make_distribution(version):
    distribution = ET.Element('installer-gui-script', {'minSpecVersion': '2'})
    ET.SubElement(distribution, 'title').text = 'Local TTS Mic'
    ET.SubElement(distribution, 'welcome', {'file': 'welcome.html', 'mime-type': 'text/html'})
    ET.SubElement(distribution, 'conclusion', {'file': 'conclusion.html', 'mime-type': 'text/html'})
    ET.SubElement(distribution, 'options', {'customize': 'never', 'hostArchitectures': 'arm64', 'require-scripts': 'false'})
    volume = ET.SubElement(distribution, 'volume-check', {'script': 'true'})
    ET.SubElement(ET.SubElement(volume, 'allowed-os-versions'), 'os-version', {'min': MIN_MACOS})
    ET.SubElement(distribution, 'domains', {'enable_localSystem': 'true', 'enable_currentUserHome': 'false', 'enable_anywhere': 'false'})
    outline = ET.SubElement(distribution, 'choices-outline')
    for name, title in [('app', 'Local TTS Mic'), ('driver', 'Virtual microphone')]:
        ET.SubElement(outline, 'line', {'choice': name})
        choice = ET.SubElement(distribution, 'choice', {'id': name, 'title': title, 'visible': 'false'})
        ET.SubElement(choice, 'pkg-ref', {'id': 'local.localspeak.' + name + '.installer'})
        ET.SubElement(distribution, 'pkg-ref', {'id': 'local.localspeak.' + name + '.installer', 'version': version}).text = name + '.pkg'
    # Driver component uses the existing installer receipt identifier.
    for ref in distribution.iter('pkg-ref'):
        if ref.get('id') == 'local.localspeak.driver.installer': ref.set('id', 'local.localspeak.mic.installer')
    close = ET.SubElement(distribution, 'pkg-ref', {'id': 'local.localspeak.app.installer'})
    ET.SubElement(ET.SubElement(close, 'must-close'), 'app', {'id': 'local.localspeak.app'})
    return distribution


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sign', action='store_true', help='Require DEVELOPER_ID_APPLICATION and DEVELOPER_ID_INSTALLER environment variables')
    parser.add_argument('--notarize', metavar='KEYCHAIN_PROFILE', help='Submit signed package, wait, staple and verify Gatekeeper')
    args = parser.parse_args()
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        parser.error('Build on an Apple Silicon Mac')
    identity = os.environ.get('DEVELOPER_ID_APPLICATION') if args.sign else '-'
    installer_identity = os.environ.get('DEVELOPER_ID_INSTALLER') if args.sign else None
    if args.sign and (not identity or not installer_identity):
        parser.error('--sign requires DEVELOPER_ID_APPLICATION and DEVELOPER_ID_INSTALLER')
    if args.notarize and not args.sign: parser.error('--notarize requires --sign')
    uv = shutil.which('uv') or '/opt/homebrew/bin/uv'
    config = json.loads((ROOT / 'resources/runtime-distribution.json').read_text())
    CACHE.mkdir(parents=True, exist_ok=True)
    python = prepare_python(config, uv)
    archive = source_archive(config)
    run(ROOT / 'scripts/build.sh', cwd=ROOT)
    if BUILD.exists(): shutil.rmtree(BUILD)
    BUILD.mkdir(parents=True)
    app = BUILD / 'app-root/Applications/Local TTS Mic.app'
    run('ditto', ROOT / 'build/Local TTS Mic.app', app)
    source = app / 'Contents/Resources/LocalTTSMic'
    source.mkdir()
    run('/bin/cp', '-cR', python, source / 'python')
    for directory in ['engine', 'resources']:
        shutil.copytree(ROOT / directory, source / directory, ignore=shutil.ignore_patterns('__pycache__'))
    (source / 'scripts').mkdir()
    for name in ['setup_packaged.py', 'download_assets.py']:
        shutil.copy2(ROOT / 'scripts' / name, source / 'scripts' / name)
    for name in ['LICENSE', 'THIRD_PARTY.md', 'TRAINING.md', 'VERSION', 'requirements.lock']:
        shutil.copy2(ROOT / name, source / name)
    shutil.copy2(archive, source / 'upstream.tar.gz')
    manifest = {'upstream': config['upstream'], 'upstreamSHA256': digest(archive), 'python': config['python']}
    manifest['runtimeID'] = hashlib.sha256((json.dumps(manifest, sort_keys=True) + digest(ROOT / 'requirements.lock') + digest(ROOT / 'resources/asset-checksums.json') + digest(ROOT / 'resources/starter-sources.json')).encode()).hexdigest()
    (source / 'runtime-manifest.json').write_text(json.dumps(manifest, indent=2))
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.pop('LocalSpeakRoot', None)
    info['LocalSpeakPackaged'] = True
    info['LSMinimumSystemVersion'] = MIN_MACOS
    info_path.write_bytes(plistlib.dumps(info))
    driver = BUILD / 'driver-root/Library/Audio/Plug-Ins/HAL/LocalSpeakMic.driver'
    run('ditto', ROOT / 'build/LocalSpeakMic.driver', driver)
    verify_relocation(app)
    sign_code(app, driver, identity)
    version = (ROOT / 'VERSION').read_text().strip()
    # A signed repair installer is available from the app's Audio settings too.
    driver_pkg = BUILD / 'driver.pkg'
    component(driver.parent.parent.parent.parent.parent, driver_pkg, 'local.localspeak.mic.installer', version, ROOT / 'driver/installer-scripts')
    if installer_identity:
        signed = BUILD / 'driver-signed.pkg'
        run('productsign', '--sign', installer_identity, driver_pkg, signed)
        signed.replace(driver_pkg)
        if args.notarize:
            run('xcrun', 'notarytool', 'submit', driver_pkg, '--keychain-profile', args.notarize, '--wait')
            run('xcrun', 'stapler', 'staple', driver_pkg)
            run('xcrun', 'stapler', 'validate', driver_pkg)
    shutil.copy2(driver_pkg, source / 'Local TTS Mic Driver.pkg')
    # Adding the nested repair package changes the outer resource seal.
    sign_args = ['codesign', '--force', '--sign', identity]
    if identity != '-': sign_args += ['--timestamp', '--options', 'runtime']
    run(*sign_args, app)
    run('codesign', '--verify', '--deep', '--strict', app)
    app_pkg = BUILD / 'app.pkg'
    component(BUILD / 'app-root', app_pkg, 'local.localspeak.app.installer', version)
    distribution = make_distribution(version)
    distribution_path = BUILD / 'Distribution.xml'
    ET.ElementTree(distribution).write(distribution_path, encoding='utf-8', xml_declaration=True)
    suffix = '' if args.sign else '-unsigned'
    output = BUILD / f'local-tts-mic-{version}-arm64{suffix}.pkg'
    command = ['productbuild', '--distribution', distribution_path, '--resources', ROOT / 'resources/packaging', '--package-path', BUILD]
    if installer_identity: command += ['--sign', installer_identity]
    run(*command, output)
    if args.sign: run('pkgutil', '--check-signature', output)
    if args.notarize:
        run('xcrun', 'notarytool', 'submit', output, '--keychain-profile', args.notarize, '--wait')
        run('xcrun', 'stapler', 'staple', output)
        run('xcrun', 'stapler', 'validate', output)
        run('spctl', '--assess', '--type', 'install', '--verbose', output)
    (BUILD / 'SHA256SUMS').write_text(f'{digest(output)}  {output.name}\n')
    print(f'\nInstaller: {output}')
    if not args.sign: print('UNSIGNED PREVIEW: not Developer ID signed or notarized. Clearly label this limitation if publishing.')


if __name__ == '__main__':
    main()
