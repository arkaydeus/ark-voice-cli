#!/usr/bin/env python3
"""Exercise release/CI shell control flow without signing, models, or network.

Run with python3 Scripts/test-release-workflows.py on macOS. The archive test
uses real ditto/unzip; external build, signing and model commands are fixtures.
"""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent

COMMAND = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get('CASE', '')
if name == 'git':
    if args == ['rev-parse', '--short', 'HEAD']: print('fixture')
elif name == 'lipo': print('arm64')
elif name == 'otool': print('no compatibility library needed')
elif name == 'xattr': pass
elif name == 'sleep': time.sleep(0.005)
elif name == 'codesign':
    if '--display' in args: print('flags=runtime\nTimestamp=fixture')
    if mode == 'sign' and '--force' in args:
        print('injected signing rejection', file=sys.stderr); sys.exit(1)
    if mode == 'verify' and '--check-notarization' in args:
        print('injected notarized verification rejection', file=sys.stderr); sys.exit(1)
elif name == 'spctl':
    if mode == 'gatekeeper':
        print('rejected: injected Gatekeeper assessment', file=sys.stderr); sys.exit(3)
    print('source=Notarized Developer ID')
elif name == 'xcrun':
    if args[:2] == ['--find', 'swift']: print('/fixture/bin/swift')
    elif args[:2] == ['notarytool', 'log']: print('injected notary log')
    elif mode == 'notary-command':
        print('injected notary command failure'); sys.exit(1)
    elif mode == 'notary-malformed': print('{}')
    else: print(json.dumps({'id': 'fixture', 'status': 'Invalid' if mode == 'notary-rejected' else 'Accepted'}))
elif name == 'swift':
    if '--show-bin-path' in args: print(str(pathlib.Path('.build/debug').resolve()))
    elif args and args[0] == 'test':
        with open('test-calls.jsonl', 'a') as f:
            f.write(json.dumps({'args': args, 'audio': os.environ.get('ARK_VOICE_INTEGRATION_STT_AUDIO'), 'words': os.environ.get('ARK_VOICE_INTEGRATION_STT_WORDS')}) + '\n')
        print('Test run with 1 test passed')
'''

BINARY = r'''#!/usr/bin/env python3
import os, pathlib, signal, socket, sys, time
args = sys.argv[1:]
mode = os.environ.get('CASE', '')
if args == ['--version']:
    if mode == 'quarantined-version' and '/verify/' in sys.argv[0]: sys.exit(1)
    print('ark-voice 0.2.0')
elif args == ['models']:
    if mode != 'missing-default':
        print('Parakeet TDT 0.6B v2 INT8 [downloaded]\nChatterbox Turbo 6-bit [downloaded]\nS3TokenizerV2 [downloaded]')
    if mode not in ('missing-optional', 'missing-ultra'):
        print('Parakeet Ultra (Core ML) [downloaded]')
    if mode not in ('missing-optional', 'missing-qwen'):
        print('Qwen3-ASR 1.7B 8-bit [downloaded]')
elif args[0] == 'serve':
    print('injected serve diagnostics', file=sys.stderr, flush=True)
    if mode == 'serve-dead': sys.exit(1)
    if mode != 'serve-timeout':
        sock = socket.socket(socket.AF_UNIX)
        sock.bind(args[args.index('--socket') + 1])
    while True: time.sleep(1)
else:
    if args[0] == 'client': args = args[1:]
    if args[0] == 'tts':
        pathlib.Path(args[args.index('-o') + 1]).write_bytes(b'fixture audio')
    elif args[0] == 'stt':
        if mode == 'recognizer' and '--model' in args:
            print('injected recognizer diagnostics', file=sys.stderr); sys.exit(2)
        print('This signed build speaks and listens. The server answers every request quickly.')
    elif args[0] == 'status': print('synthesis model loaded: true')
'''


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ark-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ['Scripts', 'Sources/ArkVoiceCLI', '.build/release', '.build/debug/Fixture.xctest/Contents/MacOS', 'bin', 'tmp']:
            (self.root / directory).mkdir(parents=True)
        for name in ['package-release.sh', 'ci.sh']:
            shutil.copy2(ROOT / 'Scripts' / name, self.root / 'Scripts' / name)
        self.write('Scripts/build-release.sh', '#!/bin/bash\nexit 0\n', True)
        self.write('Sources/ArkVoiceCLI/App.swift', 'let arkVoiceVersion = "0.2.0"\n')
        self.write('THIRD_PARTY_NOTICES.md', 'fixture notices')
        self.write('.build/release/mlx.metallib', 'fixture Metal data')
        self.write('.build/release/ark-voice', BINARY, True)
        self.write('bin/command', COMMAND, True)
        for name in ['git', 'lipo', 'otool', 'xattr', 'sleep', 'codesign', 'spctl', 'xcrun', 'swift']:
            (self.root / 'bin' / name).symlink_to('command')
        self.env = {key: value for key, value in os.environ.items() if not key.startswith('ARK_VOICE_')}
        self.env.update(PATH=str(self.root / 'bin') + ':' + os.environ['PATH'], TMPDIR=str(self.root / 'tmp'))

    def write(self, path, content, executable=False):
        target = self.root / path
        target.write_text(content)
        if executable:
            target.chmod(0o755)

    def run_script(self, script, mode='', **env):
        result = subprocess.run(['bash', f'Scripts/{script}.sh'], cwd=self.root,
                                env=dict(self.env, CASE=mode, **env), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        self.assertEqual(list((self.root / 'tmp').iterdir()), [], result.stdout)
        return result

    def test_package_failure_paths_leave_no_artifacts(self):
        cases = {
            'sign': ['injected signing rejection', 'codesign failed'],
            'notary-command': ['injected notary command failure', 'notarytool failed'],
            'notary-rejected': ['injected notary log', 'notarization was not accepted'],
            'notary-malformed': ['malformed submission data'],
            'verify': ['injected notarized verification rejection'],
            'gatekeeper': ['rejected: injected Gatekeeper assessment', 'Gatekeeper did not accept', 'status 3'],
            'quarantined-version': ['quarantined executable did not run'],
            'serve-dead': ['injected serve diagnostics', 'serve did not start'],
            'serve-timeout': ['injected serve diagnostics', 'serve did not start'],
            'recognizer': ['injected recognizer diagnostics', 'stt --model parakeet-ultra failed'],
        }
        for mode, messages in cases.items():
            with self.subTest(mode=mode):
                result = self.run_script('package-release', mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                for message in messages:
                    self.assertIn(message, result.stdout)
                self.assertEqual(list((self.root / 'dist').glob('*')), [], result.stdout)

    def test_successful_archive_and_checksum_without_metadata(self):
        # Real macOS extended attributes must not turn into AppleDouble entries.
        subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.provenance', 'fixture', str(self.root / '.build/release/mlx.metallib')], check=True)
        result = self.run_script('package-release')
        self.assertEqual(result.returncode, 0, result.stdout)
        archive = next((self.root / 'dist').glob('*.zip'))
        listing = subprocess.check_output(['unzip', '-Z1', str(archive)], text=True).splitlines()
        self.assertTrue(listing)
        self.assertFalse(any(part == '__MACOSX' or part.startswith('._') for entry in listing for part in entry.split('/')), listing)
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(set(zipped.namelist()), {
                'ark-voice-0.2.0-macos-arm64/',
                'ark-voice-0.2.0-macos-arm64/ark-voice',
                'ark-voice-0.2.0-macos-arm64/mlx.metallib',
                'ark-voice-0.2.0-macos-arm64/THIRD_PARTY_NOTICES.md',
            })
        subprocess.run(['shasum', '-a', '256', '-c', archive.name + '.sha256'], cwd=archive.parent, check=True, capture_output=True)

    def test_failed_replacement_preserves_previous_verified_release(self):
        dist = self.root / 'dist'
        dist.mkdir()
        self.write('dist/ark-voice-0.2.0-macos-arm64.zip', 'previous verified release')
        self.write('dist/ark-voice-0.2.0-macos-arm64.zip.sha256', 'previous checksum')
        result = self.run_script('package-release', 'gatekeeper')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((dist / 'ark-voice-0.2.0-macos-arm64.zip').read_text(), 'previous verified release')
        self.assertEqual((dist / 'ark-voice-0.2.0-macos-arm64.zip.sha256').read_text(), 'previous checksum')

    def test_ci_model_skip_branches(self):
        for mode, message in [('missing-default', 'SKIP  Integration tests'), ('missing-optional', 'needs parakeet-ultra and qwen'), ('missing-ultra', 'needs parakeet-ultra and qwen'), ('missing-qwen', 'needs parakeet-ultra and qwen')]:
            with self.subTest(mode=mode):
                result = self.run_script('ci', mode)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn(message, result.stdout)
                self.assertIn('CI passed.', result.stdout)
                self.assertFalse((self.root / '.build/debug/Fixture.xctest/Contents/MacOS/mlx.metallib').exists())

    def test_ci_custom_audio_and_expected_words(self):
        self.write('custom.wav', 'fixture audio')
        result = self.run_script('ci', ARK_VOICE_INTEGRATION_STT_AUDIO=str(self.root / 'custom.wav'), ARK_VOICE_INTEGRATION_STT_WORDS='hello world')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('Synthesize STT sample', result.stdout)
        calls = [json.loads(line) for line in (self.root / 'test-calls.jsonl').read_text().splitlines()]
        integration = next(call for call in calls if 'IntegrationTests' in call['args'])
        self.assertEqual(integration['audio'], str(self.root / 'custom.wav'))
        self.assertEqual(integration['words'], 'hello world')
        self.assertIn('PASS  Optional recognizer tests', result.stdout)

    def test_ci_custom_audio_requires_expected_words(self):
        self.write('custom.wav', 'fixture audio')
        result = self.run_script('ci', ARK_VOICE_INTEGRATION_STT_AUDIO=str(self.root / 'custom.wav'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('set ARK_VOICE_INTEGRATION_STT_WORDS', result.stdout)

    def test_ci_generated_audio_has_expected_words(self):
        result = self.run_script('ci')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('PASS  Synthesize STT sample', result.stdout)
        calls = [json.loads(line) for line in (self.root / 'test-calls.jsonl').read_text().splitlines()]
        self.assertEqual(next(call for call in calls if 'IntegrationTests' in call['args'])['words'], 'short recording local test run')


class DependencyAuditTests(unittest.TestCase):
    def test_rejects_unapproved_code_and_license_changes(self):
        spec = importlib.util.spec_from_file_location('release_audit', ROOT / 'Scripts/check-release-dependencies.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'LICENSE').write_text('approved license')
            node = {'identity': 'fixture', 'path': temporary, 'dependencies': [], 'version': '1.0'}
            graph = {'identity': 'root', 'path': temporary, 'dependencies': [node]}
            pins = [{'identity': 'fixture', 'state': {'version': '1.0', 'revision': 'abc'}}]
            audit = [{'identity': 'fixture', 'version': '1.0', 'revision': 'abc',
                      'license_file': 'LICENSE', 'license_sha256': hashlib.sha256(b'approved license').hexdigest()}]
            module.check(graph, pins, audit)
            with self.assertRaisesRegex(ValueError, 'matching license audit'):
                changed = copy.deepcopy(pins)
                changed[0]['state']['revision'] = 'unreviewed'
                module.check(graph, changed, audit)
            with self.assertRaisesRegex(ValueError, 'license text changed'):
                (root / 'LICENSE').write_text('changed terms')
                module.check(graph, pins, audit)
            (root / 'LICENSE').write_text('approved license')
            with self.assertRaisesRegex(ValueError, 'no approved redistribution grant'):
                graph['dependencies'].append({'identity': 'swift-xet', 'dependencies': []})
                module.check(graph, pins, audit)
            graph['dependencies'].pop()
            with self.assertRaisesRegex(ValueError, 'unexpected unpinned'):
                graph['dependencies'].append({'identity': 'unknown', 'dependencies': []})
                module.check(graph, pins, audit)


if __name__ == '__main__':
    unittest.main(verbosity=2)
