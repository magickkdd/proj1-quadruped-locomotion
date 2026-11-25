"""Apply or restore the flat-ground Go2 evaluation/training config patch.

Usage:
    python go2_flat_patch.py apply   <repo_dir> <backup_dir>
    python go2_flat_patch.py restore <repo_dir> <backup_dir>
"""
import pathlib
import shutil
import sys

ROBOT_REL = 'legged_gym/envs/go2/go2.py'
CONFIG_REL = 'legged_gym/envs/go2/go2_config.py'

ROBOT_REPLACEMENTS = (
    (
        'torch_rand_float(-0.2, 0.2, (len(env_ids), 4), self.device)',
        'torch.zeros((len(env_ids), 4), device=self.device)',
        1,
    ),
    (
        'torch_rand_float(-0.4, 0.4, (len(env_ids), 4), self.device)',
        'torch.zeros((len(env_ids), 4), device=self.device)',
        2,
    ),
)

CONFIG_REPLACEMENTS = (
    ('        randomize_friction = True', '        randomize_friction = False'),
    ('        randomize_base_mass = True', '        randomize_base_mass = False'),
    ('        push_robots = True', '        push_robots = False'),
    ('        randomize_com_displacement = True', '        randomize_com_displacement = False'),
    ('        heading_command = True', '        heading_command = False'),
)


def apply_patch(repo_dir, backup_dir):
    repo = pathlib.Path(repo_dir)
    backup = pathlib.Path(backup_dir)
    backup.mkdir(parents=True, exist_ok=True)

    robot = repo / ROBOT_REL
    config = repo / CONFIG_REL
    for path in (robot, config):
        if not path.is_file():
            raise SystemExit('missing config file: %s' % path)
        stored = backup / path.name
        if not stored.exists():
            shutil.copy2(path, stored)

    source = robot.read_text()
    applied = 0
    for old, new, limit in ROBOT_REPLACEMENTS:
        if old not in source:
            continue
        source = source.replace(old, new, limit)
        applied += 1
    robot.write_text(source)
    print('robot_patch_groups_applied=%d' % applied)

    source = config.read_text()
    applied = 0
    for old, new in CONFIG_REPLACEMENTS:
        if old in source:
            source = source.replace(old, new)
            applied += 1
    config.write_text(source)
    print('config_patch_groups_applied=%d' % applied)

    for path in (robot, config):
        text = path.read_text()
        for marker in ('randomize_friction = False', 'randomize_base_mass = False',
                       'push_robots = False', 'randomize_com_displacement = False',
                       'heading_command = False'):
            print('patch_marker_%s=%s' % (marker.split(' =')[0].strip(), marker in text))
    dof_patch = 'torch_rand_float(-0.2, 0.2, (len(env_ids), 4), self.device)' not in robot.read_text()
    print('reset_noise_patch_applied=%s' % dof_patch)


def restore_patch(repo_dir, backup_dir):
    repo = pathlib.Path(repo_dir)
    backup = pathlib.Path(backup_dir)
    restored = 0
    for rel in (ROBOT_REL, CONFIG_REL):
        stored = backup / pathlib.Path(rel).name
        target = repo / rel
        if stored.is_file():
            shutil.copy2(stored, target)
            restored += 1
    print('config_restored=%d' % restored)


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ('apply', 'restore'):
        raise SystemExit(__doc__)
    action, repo_dir, backup_dir = sys.argv[1:]
    if action == 'apply':
        apply_patch(repo_dir, backup_dir)
    else:
        restore_patch(repo_dir, backup_dir)


if __name__ == '__main__':
    main()
