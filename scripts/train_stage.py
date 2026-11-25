"""Train one curriculum stage with the terrain level pinned.

This is a drop-in replacement for ``python -m legged_gym.scripts.train`` that
additionally pins every environment to a fixed terrain difficulty row, so that
promotion happens only when the outer staged-curriculum job decides it is
earned.

Environment variables:
    PIN_TERRAIN_LEVEL   row index to pin (0 = easiest, 9 = hardest)
    PIN_TERRAIN_TYPES   optional comma separated column list (default: all)
"""
import os

import isaacgym  # noqa: F401  must be imported before torch
import torch

from legged_gym.envs import *  # noqa: F401,F403  registers all tasks
from legged_gym.utils import get_args, task_registry


def pin_terrain(env, level, types=None):
    sim = env.simulator
    sim._terrain_levels[:] = level
    if types is not None:
        sim._terrain_types[:] = torch.tensor(types, device=sim._terrain_types.device, dtype=sim._terrain_types.dtype)
    # Freeze the built-in curriculum: promotion is decided by the outer job.
    env._update_terrain_curriculum = lambda *args, **kwargs: None
    sim.update_terrain_curriculum = lambda *args, **kwargs: None
    sim._env_origins[:] = sim._terrain_origins[sim._terrain_levels, sim._terrain_types]
    env.reset_idx(torch.arange(env.num_envs, device=env.device))
    if hasattr(env, 'episode_length_buf'):
        env.episode_length_buf.zero_()
    print('pinned_terrain_level=%d' % level, flush=True)
    print('pinned_terrain_types_min=%d' % int(sim._terrain_types.min().item()), flush=True)
    print('pinned_terrain_types_max=%d' % int(sim._terrain_types.max().item()), flush=True)
    heights = sim._root_states[:, 2]
    print('pinned_spawn_height_min=%.4f mean=%.4f max=%.4f' % (
        float(heights.min().item()), float(heights.mean().item()), float(heights.max().item())), flush=True)


def main():
    args = get_args()
    env, env_cfg = task_registry.make_env(name=args.task, args=args)

    level = os.environ.get('PIN_TERRAIN_LEVEL')
    if level is not None and level != '':
        types_env = os.environ.get('PIN_TERRAIN_TYPES', '').strip()
        types = [int(item) for item in types_env.split(',') if item.strip()] if types_env else None
        pin_terrain(env, int(level), types)

    runner, train_cfg = task_registry.make_alg_runner(env=env, name=args.task, args=args)
    print('stage_log_dir=%s' % runner.log_dir, flush=True)
    print('stage_start_iteration=%d' % runner.current_learning_iteration, flush=True)
    runner.learn(num_learning_iterations=train_cfg.runner.max_iterations,
                 init_at_random_ep_len=True)
    print('stage_end_iteration=%d' % runner.current_learning_iteration, flush=True)


if __name__ == '__main__':
    main()
