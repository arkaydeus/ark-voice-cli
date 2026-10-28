#!/usr/bin/env python3
"""Reject release dependency or license changes until their audit is updated."""
import hashlib
import json
from pathlib import Path
import sys


def check(graph, pins, audit):
    expected = {entry['identity']: entry for entry in audit}
    locked = {entry['identity']: entry['state'] for entry in pins}
    seen = set()
    if set(locked) != set(expected):
        raise ValueError('lockfile and license audit inventories differ')
    for identity, entry in expected.items():
        if any(locked[identity].get(key) != entry[key] for key in ('version', 'revision')):
            raise ValueError(f'{identity}: pinned source has no matching license audit')

    def visit(node):
        identity = node['identity']
        if identity == 'swift-xet' or (identity == 'swift-huggingface' and 'Xet' in node.get('traits', [])):
            raise ValueError('Xet has no approved redistribution grant; disable the Xet trait')
        if identity in locked:
            entry = expected[identity]
            if node['version'] != entry['version']:
                raise ValueError(f'{identity}: resolved version differs from audited pin')
            license_path = Path(node['path']) / entry['license_file']
            if hashlib.sha256(license_path.read_bytes()).hexdigest() != entry['license_sha256']:
                raise ValueError(f'{identity}: license text changed since audit')
            seen.add(identity)
        elif node is not graph and identity != 'mlx-audio-swift':
            raise ValueError(f'{identity}: unexpected unpinned dependency')
        for child in node['dependencies']:
            visit(child)

    visit(graph)
    # SwiftPM can omit swift-syntax when using prebuilt macro plugins. Its
    # pinned license is still checked even though no source target is built.
    for identity in set(locked) - seen:
        entry = expected[identity]
        if not entry.get('prebuilt_macro'):
            raise ValueError(f'{identity}: locked package is absent from resolved graph')
        license_path = Path(graph['path']) / '.build/checkouts' / identity / entry['license_file']
        if hashlib.sha256(license_path.read_bytes()).hexdigest() != entry['license_sha256']:
            raise ValueError(f'{identity}: license text changed since audit')
    print(f'License audit passed: {len(locked)} pinned packages; Xet excluded.')


if __name__ == '__main__':
    root = Path(__file__).resolve().parent.parent
    try:
        check(json.loads(Path(sys.argv[1]).read_text()),
              json.loads((root / 'Package.resolved').read_text())['pins'],
              json.loads((root / 'Docs/release-dependencies.json').read_text()))
    except (ValueError, OSError, KeyError, IndexError) as error:
        sys.exit(f'error: release dependency audit failed: {error}')
