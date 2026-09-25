#!/usr/bin/env python3
"""Build-only metadata helpers; never rewrite the files shipped in packages."""
import argparse
from pathlib import Path
import re


def stage_pkgconfig(stage, destination):
    stage = Path(stage).resolve()
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for directory in ('usr/lib/pkgconfig', 'usr/share/pkgconfig'):
        for source in sorted((stage / directory).glob('*.pc')):
            original = source.read_text()
            variables = dict(re.findall(r'^([\w]+)=(.*)$', original, re.MULTILINE))

            def expand(value):
                for _ in range(len(variables) + 1):
                    expanded = re.sub(r'\$\{(\w+)\}', lambda m: variables.get(m[1], m[0]), value)
                    if expanded == value:
                        return value
                    value = expanded
                raise ValueError(f'Cyclic pkg-config variables in {source}')

            lines = []
            for line in original.splitlines():
                # GNOME Shell embeds typelibdir into its installed binary/RPATH.
                # Keep that runtime path native while relocating build inputs.
                if line.startswith('typelibdir='):
                    line = 'typelibdir=' + expand(line.split('=', 1)[1])
                else:
                    line = re.sub(r'(?<![\w/])(/usr)(?=/|$)', lambda m: str(stage) + m[1], line)
                lines.append(line)
            (destination / source.name).write_text('\n'.join(lines) + '\n')


def write_pacman_config(base, repository, destination):
    original = Path(base).read_text()
    headers = list(re.finditer(r'^\s*\[([^]\n]+)\]\s*(?:#.*)?$', original, re.MULTILINE))
    if not headers or headers[0][1] != 'options':
        raise ValueError('Base pacman.conf must start with an [options] section')
    if any(header[1] == 'horizon-patched' for header in headers):
        raise ValueError('Base pacman.conf already defines horizon-patched')
    position = headers[1].start() if len(headers) > 1 else len(original)
    block = ('\n[horizon-patched]\nSigLevel = Never\nServer = '
             + Path(repository).resolve().as_uri() + '\n\n')
    Path(destination).write_text(original[:position] + block + original[position:])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    stage = commands.add_parser('stage-pkgconfig')
    stage.add_argument('stage')
    stage.add_argument('destination')
    config = commands.add_parser('pacman-config')
    config.add_argument('base')
    config.add_argument('repository')
    config.add_argument('destination')
    args = parser.parse_args()
    if args.command == 'stage-pkgconfig':
        stage_pkgconfig(args.stage, args.destination)
    else:
        write_pacman_config(args.base, args.repository, args.destination)
