#!/usr/bin/env python3
"""Prepare a stable version and release notes from the checked-out commit."""
import argparse
import json
from pathlib import Path
import re
import subprocess

VERSION = re.compile(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)')


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def parse_version(value):
    match = VERSION.fullmatch(value)
    if not match:
        raise ValueError('Use a stable semantic version, for example 0.1.0.')
    return tuple(map(int, match.groups()))


def prepare(explicit_version, initial_version, output):
    sha = git('rev-parse', 'HEAD')
    tags = {}
    for tag in git('tag', '--list', 'v*').splitlines():
        if VERSION.fullmatch(tag[1:]):
            tags[parse_version(tag[1:])] = tag
    at_head = set(git('tag', '--points-at', 'HEAD').splitlines())
    current = [version for version, tag in tags.items() if tag in at_head]
    latest = max(tags) if tags else None
    if explicit_version:
        version = parse_version(explicit_version)
        if version in tags and tags[version] not in at_head:
            raise ValueError('That version already belongs to another commit.')
        if latest and version < latest:
            raise ValueError('The version must not go backwards.')
    elif current:
        version = max(current)
    elif latest:
        version = (latest[0], latest[1], latest[2] + 1)
    else:
        version = parse_version(initial_version)
    value = '.'.join(map(str, version))
    prior = [v for v in tags if v < version]
    previous_tag = tags[max(prior)] if prior else None
    revision = f'{previous_tag}..HEAD' if previous_tag else 'HEAD'
    messages = git('log', '--first-parent', '--format=%B%x00', revision).split('\x00')
    changes = []
    for message in messages:
        lines = [line.strip() for line in message.strip().splitlines() if line.strip()]
        if not lines:
            continue
        title = lines[1] if lines[0].startswith('Merge pull request ') and len(lines) > 1 else lines[0]
        title = re.sub(r'^(?:feat|fix|perf|test|docs|refactor|build|ci|chore)(?:\([^)]*\))?!?:\s*', '', title)
        if title not in changes:
            changes.append(title)
    notes = 'Свіжа збірка Studio Recorder вже тут 👋\n\nЩо підкрутили цього разу:\n\n'
    notes += '\n'.join(f'- {title}' for title in changes) or '- Нова збірка поточного стану програми.'
    notes += f'\n\nЗібрано з `{sha}`. Для Apple Silicon і macOS 26+.\n'
    output.mkdir(parents=True, exist_ok=True)
    (output / 'notes.md').write_text(notes, encoding='utf-8')
    plan = {'version': value, 'tag': f'v{value}', 'sha': sha,
            'asset': f'Studio-Recorder-{value}-macOS-arm64.zip'}
    (output / 'release.json').write_text(json.dumps(plan), encoding='utf-8')
    for key, item in plan.items():
        print(f'{key}={item}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='')
    parser.add_argument('--initial-version', default='0.1.0')
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    try:
        prepare(args.version, args.initial_version, args.output_dir)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')
