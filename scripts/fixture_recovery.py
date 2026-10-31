"""Archive only a test's UUID-owned recovery files after its children exit."""
from pathlib import Path
import hashlib
import json
import os
import stat
import uuid

def pin(value):
    return (value.st_dev, value.st_ino, value.st_uid, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns)

def directory_pin(value):
    return (value.st_dev, value.st_ino, value.st_uid, value.st_mode)

def archive_recovery(folder):
    assert folder.parent == Path('/tmp')
    prefix = 'nn-deck-test-' + str(os.getuid()) + '-'
    assert folder.name.startswith(prefix)
    uuid.UUID(folder.name[len(prefix):])
    root = folder / 'companion-recovery'
    if not os.path.lexists(root):
        return
    info = root.lstat()
    assert stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700
    names = list(root.iterdir())
    assert len(names) <= 130
    snapshots = {}
    total = 0
    for path in names:
        if path.name not in ['ledger-v1.json', '.ledger.lock']:
            assert path.name.startswith('.ledger-') and path.name.endswith('.tmp')
            uuid.UUID(path.name[8:-4])
        before = path.lstat()
        assert stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
        assert stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1
        assert 0 <= before.st_size <= 50_331_648
        total += before.st_size
        assert total <= 100_663_296
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as stream:
            assert pin(os.fstat(stream.fileno())) == pin(before)
            data = stream.read(before.st_size + 1)
            assert len(data) == before.st_size and pin(os.fstat(stream.fileno())) == pin(before)
        assert pin(path.lstat()) == pin(before)
        snapshots[path.name] = (before, data)
    destination = Path(os.environ.get('DECK_RECOVERY_EVIDENCE', str(Path.cwd() / 'build/recovery-evidence'))) / folder.name
    destination.mkdir(parents=True, mode=0o700, exist_ok=False)
    pins = {}
    for name, (before, data) in snapshots.items():
        target = destination / name
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        assert target.read_bytes() == data
        pins[name] = hashlib.sha256(data).hexdigest()
    with (destination / 'fixture-archive.json').open('x') as stream:
        json.dump({'scope': 'Authored test data, not installed profiles', 'source': str(root), 'pins': pins}, stream, indent=2)
    assert directory_pin(root.lstat()) == directory_pin(info) and {p.name for p in root.iterdir()} == set(snapshots)
    for name, (before, _) in snapshots.items():
        path = root / name
        assert pin(path.lstat()) == pin(before)
        path.unlink()
    root.rmdir()
