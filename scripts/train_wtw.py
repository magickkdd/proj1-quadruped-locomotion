"""Train go2_wtw with terrain rows spread over the full difficulty range.

Only one behaviour is changed relative to the stock entry point: the initial
terrain rows are sampled uniformly over all rows instead of only the first few.
The curriculum logic itself is left untouched.
"""
import os

import isaacgym  # noqa: F401  must precede torch
import torch

from legged_gym.envs import *  # noqa: F401,F403
from legged_gym.utils import get_args, task_registry


def spread_initial_terrain(env):
    sim = env.simulator
    device = sim._terrain_levels.device
    levels = torch.randint(0, int(sim._max_terrain_level), (env.num_envs,), device=device)
    sim._terrain_levels[:] = levels
    sim._env_origins[:] = sim._terrain_origins[sim._terrain_levels, sim._terrain_types]
    env.reset_idx(torch.arange(env.num_envs, device=env.device))
    if hasattr(env, 'episode_length_buf'):
        env.episode_length_buf.zero_()
    print('init_terrain_random=1 mean_level=%.3f min=%d max=%d' % (
        float(sim._terrain_levels.float().mean().item()),
        int(sim._terrain_levels.min().item()),
        int(sim._terrain_levels.max().item())), flush=True)


def main():
    args = get_args()
    env, env_cfg = task_registry.make_env(name=args.task, args=args)
    if os.environ.get('INIT_TERRAIN_RANDOM', '1') == '1':
        spread_initial_terrain(env)
    runner, train_cfg = task_registry.make_alg_runner(env=env, name=args.task, args=args)
    print('stage_log_dir=%s' % runner.log_dir, flush=True)
    runner.learn(num_learning_iterations=train_cfg.runner.max_iterations,
                 init_at_random_ep_len=True)
    print('train_end_iteration=%d' % runner.current_learning_iteration, flush=True)


if __name__ == '__main__':
    main()
