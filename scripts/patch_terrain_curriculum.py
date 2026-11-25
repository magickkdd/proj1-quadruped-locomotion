"""Patch or restore the Go2 terrain curriculum initial level.

Searches the whole legged_gym tree because the default may live in a shared
base config, and tolerates optional type annotations such as
``max_init_terrain_level: int = 1``.

Usage:
    python patch_terrain_curriculum.py apply   <repo_dir> <backup_dir> <level>
    python patch_terrain_curriculum.py restore <repo_dir> <backup_dir>
"""
import pathlib
import re
import shutil
import sys

TOKEN = 'max_init_terrain_level'
SUBSTITUTIONS = (
    re.compile(r'(' + TOKEN + r'\s*(?::[^=\n]+)?=\s*)\d+'),
    re.compile(r'(setattr\([^,]+,\s*[\'"]' + TOKEN + r'[\'"],\s*)\d+'),
    re.compile(r'([\'"]' + TOKEN + r'[\'"]\s*:\s*)\d+'),
)
FIND_PATTERN = re.compile(TOKEN)


def iter_python_files(repo):
    root = pathlib.Path(repo) / 'legged_gym'
    if not root.is_dir():
        raise SystemExit('missing legged_gym directory: %s' % root)
    for path in sorted(root.rglob('*.py')):
        yield path


def apply(repo, backup, level):
    repo_path = pathlib.Path(repo)
    backup_path = pathlib.Path(backup)
    patched_files = 0
    replacements = 0
    found_lines = []
    for path in iter_python_files(repo):
        text = path.read_text()
        if TOKEN not in text:
            continue
        rel = path.relative_to(repo_path)
        for lineno, line in enumerate(text.splitlines(), 1):
            if TOKEN in line:
                found_lines.append('%s:%d:%s' % (rel, lineno, line.strip()))
        updated, count = None, 0
        for pattern in SUBSTITUTIONS:
            updated, hits = pattern.subn(r'\g<1>%d' % level, text)
            if hits:
                text = updated
                count += hits
        if count == 0:
            continue
        stored = backup_path / (str(rel) + '.original')
        stored.parent.mkdir(parents=True, exist_ok=True)
        if not stored.exists():
            shutil.copy2(path, stored)
        path.write_text(updated)
        patched_files += 1
        replacements += count
        print('terrain_curriculum_patched=%s replacements=%d level=%d' % (rel, count, level), flush=True)

    for item in found_lines:
        print('terrain_curriculum_definition=%s' % item, flush=True)
    print('terrain_curriculum_files_patched=%d' % patched_files, flush=True)
    print('terrain_curriculum_replacements=%d' % replacements, flush=True)

    if patched_files == 0:
        if found_lines:
            raise SystemExit('found the token but no numeric assignment to patch; see definitions above')
        raise SystemExit('no %s definition found anywhere under legged_gym' % TOKEN)


def restore(repo, backup):
    repo_path = pathlib.Path(repo)
    backup_path = pathlib.Path(backup)
    if not backup_path.is_dir():
        print('terrain_curriculum_restored=0', flush=True)
        return
    restored = 0
    for stored in sorted(backup_path.rglob('*.original')):
        rel = str(stored.relative_to(backup_path))
        if not rel.endswith('.original'):
            continue
        target = repo_path / rel[:-len('.original')]
        if target.is_file():
            shutil.copy2(stored, target)
            restored += 1
    print('terrain_curriculum_restored=%d' % restored, flush=True)


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ('apply', 'restore'):
        raise SystemExit(__doc__)
    action = sys.argv[1]
    if action == 'apply':
        if len(sys.argv) != 5:
            raise SystemExit(__doc__)
        apply(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    else:
        restore(sys.argv[2], sys.argv[3])


if __name__ == '__main__':
    main()
