#!/usr/bin/env python3
"""Update the official tap from the latest published stable release. Safe to retry."""
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

REPO = 'IGOLz/GameEdge'
TAP = 'IGOLz/homebrew-tap'
CASK = 'Casks/gameedge.rb'


def gh(*args, payload=None):
    return subprocess.run(['gh', *args], input=json.dumps(payload) if payload else None,
                          text=True, capture_output=True, check=True).stdout


def render(tag, checksum):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('Expected a stable vX.Y.Z tag')
    if not re.fullmatch(r'[0-9a-f]{64}', checksum):
        raise ValueError('Expected a SHA-256 checksum')
    template = Path(__file__).with_name('homebrew') / 'gameedge.rb.in'
    return template.read_text().replace('@VERSION@', tag[1:]).replace('@SHA256@', checksum)


def update(tag):
    release = json.loads(gh('api', f'repos/{REPO}/releases/latest'))
    if release['draft'] or release['prerelease'] or release['tag_name'] != tag:
        raise ValueError('Only the latest published stable release can update the tap')
    render(tag, '0' * 64)  # Validate before using the tag in filenames.
    dmg = f'GameEdge-{tag[1:]}.dmg'
    with tempfile.TemporaryDirectory() as directory:
        gh('release', 'download', tag, '--repo', REPO, '--dir', directory,
           '--pattern', dmg, '--pattern', 'SHA256SUMS.txt')
        files = Path(directory)
        checksum = hashlib.sha256((files / dmg).read_bytes()).hexdigest()
        if f'{checksum}  {dmg}' not in (files / 'SHA256SUMS.txt').read_text().splitlines():
            raise ValueError('Published DMG does not match SHA256SUMS.txt')
    content = render(tag, checksum)
    tree = json.loads(gh('api', f'repos/{TAP}/git/trees/HEAD', '-f', 'recursive=1', '--method', 'GET'))
    current = next((entry['sha'] for entry in tree['tree'] if entry['path'] == CASK), None)
    if current:
        blob = json.loads(gh('api', f'repos/{TAP}/git/blobs/{current}'))
        if base64.b64decode(blob['content']).decode() == content:
            print(f'Homebrew already offers {tag}')
            return
    payload = {'message': f'Update GameEdge to {tag[1:]}',
               'content': base64.b64encode(content.encode()).decode()}
    if current:
        payload['sha'] = current
    gh('api', f'repos/{TAP}/contents/{CASK}', '--method', 'PUT', '--input', '-', payload=payload)
    print(f'Homebrew updated to {tag}: https://github.com/{TAP}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('Usage: python3 scripts/update-homebrew.py vX.Y.Z')
    try:
        update(sys.argv[1])
    except subprocess.CalledProcessError as error:
        sys.exit(f'Homebrew update failed: {error.stderr.strip()}')
    except ValueError as error:
        sys.exit(f'Homebrew update failed: {error}')
