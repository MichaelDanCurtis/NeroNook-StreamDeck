"""Stable local signing, vendorable with a plugin; never reads credential values."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess


class SigningError(RuntimeError):
    pass


def command(args, timeout=25):
    try:
        result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise SigningError('Signing needs attention or did not finish. No retry was made. '
                           'Check the macOS request for codesign and the selected signing key when you return.') from error
    if result.returncode:
        raise SigningError('Code signing or identity verification failed. The existing app was preserved; '
                           'check the selected signing identity and Keychain access. No temporary-signing fallback was used. '
                           + result.stderr.strip()[-600:])
    return result.stdout + result.stderr


def installed_reference(bundle_id, root=None):
    root = root or Path.home()/'Library/Application Support/NeroNook/Plugins'
    registry = root/'installed-v1.json'
    if not registry.exists():
        return None
    if registry.stat().st_size > 4*1024*1024:
        raise SigningError('Installed-module registry exceeds the inspection limit.')
    for entry in json.loads(registry.read_text()):
        folder = entry.get('folder', '')
        if not re.fullmatch(r'[0-9A-Fa-f-]{36}', folder):
            raise SigningError('Invalid installed-module folder.')
        app = root/folder/'Plugin.app'
        info = app/'Contents/Info.plist'
        if info.is_file() and plistlib.loads(info.read_bytes()).get('CFBundleIdentifier') == bundle_id:
            return app
    return None


def details(app):
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    output = command(['/usr/bin/codesign', '-d', '--verbose=4', '-r-', app])
    fields = {}
    for line in output.splitlines():
        for key in ('Identifier', 'Authority', 'TeamIdentifier'):
            if line.startswith(key+'=') and key not in fields:
                fields[key] = line[len(key)+1:]
        if line.startswith('designated => '):
            fields['requirement'] = line[len('designated => '):]
    if not fields.get('Authority') or not fields.get('requirement'):
        raise SigningError('The reference app has no stable signing identity. Select a certificate explicitly for a reviewed migration.')
    return fields


def resolve(bundle_id, identity=None, reference=None):
    reference = Path(reference) if reference else installed_reference(bundle_id)
    previous = details(reference) if reference and reference.exists() else None
    if previous and previous.get('Identifier') != bundle_id:
        raise SigningError('Reference app has a different bundle identifier.')
    identity = identity or os.environ.get('NERONOOK_SIGNING_IDENTITY') or (previous or {}).get('Authority')
    if not identity or identity.strip() in ('', '-'):
        raise SigningError('Choose an established certificate with --identity or NERONOOK_SIGNING_IDENTITY. '
                           'Installable packages cannot use temporary ad hoc signing.')
    return identity, reference


def sign(app, identity, *options):
    if not identity or identity == '-':
        raise SigningError('Installable packages require a stable signing certificate.')
    command(['/usr/bin/codesign', '--force', '--sign', identity, *options, app])


def verify_update(app, reference=None):
    candidate = details(app)
    if reference and Path(reference).exists():
        previous = details(reference)
        if candidate.get('Identifier') != previous.get('Identifier'):
            raise SigningError('Update changed the app identity.')
        command(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + previous['requirement'], app])
    return candidate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['identity', 'sign', 'verify'])
    parser.add_argument('--bundle'); parser.add_argument('--identity'); parser.add_argument('--reference', type=Path)
    parser.add_argument('--entitlements', type=Path); parser.add_argument('app', type=Path, nargs='?')
    args = parser.parse_args()
    if args.operation == 'identity':
        print(resolve(args.bundle, args.identity, args.reference)[0])
    elif args.operation == 'sign':
        sign(args.app, args.identity, *(['--entitlements', str(args.entitlements)] if args.entitlements else []))
    else:
        verify_update(args.app, args.reference)


if __name__ == '__main__':
    try:
        main()
    except (SigningError, OSError, ValueError) as error:
        raise SystemExit(str(error))
