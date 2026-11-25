import argparse
import csv
import inspect
import os
import subprocess
import sys

import isaacgym
from isaacgym import gymapi
import torch

import legged_gym.envs
from legged_gym.utils import get_args, task_registry


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('--task', default='go2')
    parser.add_argument('--load_run', required=True)
    parser.add_argument('--ckpt', type=int, required=True)
    parser.add_argument('--num_envs', type=int, default=100)
    parser.add_argument('--episodes', type=int, default=100)
    parser.add_argument('--frames', type=int, default=1800)
    parser.add_argument('--fps', type=int, default=30)
    parser.add_argument('--frame_dir', required=True)
    parser.add_argument('--video', required=True)
    parser.add_argument('--csv', required=True)
    parser.add_argument('--summary', required=True)
    parser.add_argument('--state_log', required=True)
    parser.add_argument('--state_interval', type=int, default=30)
    parser.add_argument('--command_x', type=float, default=1.0)
    parser.add_argument('--checkpoint_path', default=os.environ.get('CHECKPOINT_PATH', ''))
    parser.add_argument('--terrain_level', default=os.environ.get('TERRAIN_LEVEL', 'auto'))
    parser.add_argument('--terrain_types', default=os.environ.get('TERRAIN_TYPES', 'spread'))
    return parser.parse_known_args()


def torch_load_checkpoint(path, device='cpu'):
    try:
        return torch.load(path, map_location=device, weights_only=False)
    except TypeError:
        return torch.load(path, map_location=device)


def locate_actor_critic(runner):
    for alg_name in ('alg', 'algorithm'):
        alg = getattr(runner, alg_name, None)
        if alg is None:
            continue
        for ac_name in ('actor_critic', 'policy', 'ac'):
            actor_critic = getattr(alg, ac_name, None)
            if actor_critic is not None:
                return actor_critic
    raise RuntimeError('cannot locate actor-critic module on runner')


def verify_weights_loaded(actor_critic, state_dict):
    matched = 0
    mismatched = 0
    with torch.no_grad():
        for name, parameter in actor_critic.named_parameters():
            stored = state_dict.get(name)
            if not torch.is_tensor(stored) or tuple(stored.shape) != tuple(parameter.shape):
                continue
            if torch.allclose(parameter.detach().cpu(), stored.detach().float().cpu()):
                matched += 1
            else:
                mismatched += 1
    return matched, mismatched


def load_policy_weights(runner, checkpoint_path, device):
    if not checkpoint_path:
        raise RuntimeError('checkpoint_path is empty, refusing to evaluate random weights')
    if not os.path.isfile(checkpoint_path):
        raise RuntimeError('checkpoint not found: %s' % checkpoint_path)

    payload = torch_load_checkpoint(checkpoint_path, 'cpu')
    state_dict = payload.get('model_state_dict', payload) if isinstance(payload, dict) else payload
    if not isinstance(state_dict, dict):
        raise RuntimeError('unexpected checkpoint payload: %s' % type(state_dict).__name__)

    actor_critic = locate_actor_critic(runner)
    errors = []
    try:
        runner.load(checkpoint_path, load_optimizer=False)
    except TypeError:
        try:
            runner.load(checkpoint_path)
        except Exception as exc:
            errors.append(repr(exc))
    except Exception as exc:
        errors.append(repr(exc))

    matched, mismatched = verify_weights_loaded(actor_critic, state_dict)
    print('weights_match_after_runner_load=%d' % matched, flush=True)
    if matched == 0:
        actor_critic.load_state_dict(state_dict, strict=False)
        matched, mismatched = verify_weights_loaded(actor_critic, state_dict)
        print('weights_match_after_manual_load=%d' % matched, flush=True)
    if matched == 0:
        raise RuntimeError(
            'checkpoint weights were not applied: %s errors=%s keys=%d'
            % (checkpoint_path, errors, len(state_dict))
        )

    print('checkpoint_loaded=%s' % checkpoint_path, flush=True)
    print('checkpoint_matched_tensors=%d' % matched, flush=True)
    print('checkpoint_mismatched_tensors=%d' % mismatched, flush=True)
    return matched


def tensor_mean(value, index):
    if value is None:
        return None
    if not torch.is_tensor(value):
        return None
    if value.ndim == 1:
        return float(value[index].detach().cpu())
    return float(value[index, 0].detach().cpu())


def force_command(env, command_x):
    if not hasattr(env, 'commands'):
        raise RuntimeError('environment has no commands tensor')
    env.commands[:, 0] = command_x
    if env.commands.shape[1] > 1:
        env.commands[:, 1] = 0.0
    if env.commands.shape[1] > 2:
        env.commands[:, 2] = 0.0
    if env.commands.shape[1] > 3:
        env.commands[:, 3] = 0.0


def read_policy_observation(env):
    """Normalize get_observations() for plain and teacher-student envs."""
    raw = env.get_observations()
    if torch.is_tensor(raw):
        obs, tensors = raw, [raw]
    elif isinstance(raw, (list, tuple)):
        tensors = [item for item in raw if torch.is_tensor(item)]
        if not tensors:
            raise RuntimeError('get_observations returned no tensor')
        obs = tensors[0]
    else:
        raise RuntimeError('unsupported get_observations return: %s' % type(raw).__name__)

    history = tensors[1] if len(tensors) > 1 else None
    for name in ('obs_history_buf', 'obs_history'):
        candidate = getattr(env, name, None)
        if torch.is_tensor(candidate):
            history = candidate
            break
    return obs, history


def call_policy(policy, obs, history):
    try:
        positional = [
            parameter
            for parameter in inspect.signature(policy).parameters.values()
            if parameter.kind in (parameter.POSITIONAL_ONLY, parameter.POSITIONAL_OR_KEYWORD)
        ]
    except (TypeError, ValueError):
        positional = []
    if len(positional) >= 2 and history is not None:
        actions = policy(obs, history)
    else:
        actions = policy(obs)
    if isinstance(actions, (list, tuple)):
        actions = actions[0]
    return actions


def _extract_actions(policy, obs, history, num_envs):
    with torch.no_grad():
        actions = call_policy(policy, obs, history)
    if not torch.is_tensor(actions):
        raise RuntimeError('policy returned %s' % type(actions).__name__)
    if actions.dim() != 2 or actions.shape[0] != num_envs:
        raise RuntimeError('unexpected action shape: %s' % (tuple(actions.shape),))
    return actions


def select_policy_mode(policy, obs, history, num_envs):
    """Pick the callable signature the loaded policy actually accepts."""
    try:
        positional = [
            parameter
            for parameter in inspect.signature(policy).parameters.values()
            if parameter.kind in (parameter.POSITIONAL_ONLY, parameter.POSITIONAL_OR_KEYWORD)
        ]
    except (TypeError, ValueError):
        positional = []
    print('policy_positional_args=%d' % len(positional), flush=True)

    variants = []
    if history is not None:
        variants.append(('obs_history', history))
        if history.dim() > 2:
            variants.append(('obs_history_flat', history.reshape(history.shape[0], -1)))
    variants.append(('obs_only', None))
    if len(positional) < 2:
        variants.reverse()

    last_error = None
    for name, candidate in variants:
        history_arg = candidate if name != 'obs_only' else None
        try:
            if history_arg is not None:
                with torch.no_grad():
                    actions = policy(obs, history_arg)
                if isinstance(actions, (list, tuple)):
                    actions = actions[0]
                if not torch.is_tensor(actions) or actions.dim() != 2 or actions.shape[0] != num_envs:
                    raise RuntimeError('bad action shape')
                print('policy_call_mode=%s' % name, flush=True)
                return name
            _extract_actions(policy, obs, None, num_envs)
            print('policy_call_mode=%s' % name, flush=True)
            return name
        except Exception as exc:
            last_error = exc
            print('policy_call_variant_failed=%s error=%s' % (name, repr(exc)[:180]), flush=True)
    raise RuntimeError('no working policy call variant: %s' % last_error)


def refresh_policy_observation(env, command_x):
    force_command(env, command_x)
    env.compute_observations()
    return read_policy_observation(env)


def force_terrain(env, level_spec, type_spec):
    """Pin curriculum terrain to a fixed level so evaluation is not stuck on flat tiles."""
    simulator = env.simulator
    levels = getattr(simulator, '_terrain_levels', None)
    types = getattr(simulator, '_terrain_types', None)
    origins = getattr(simulator, '_terrain_origins', None)
    if levels is None or types is None or origins is None:
        print('terrain_force=skipped reason=no_terrain_curriculum', flush=True)
        return None

    terrain_cfg = getattr(getattr(env, 'cfg', None), 'terrain', None)
    if terrain_cfg is not None:
        for key in ('terrain_type', 'terrain_proportions', 'num_rows', 'num_cols',
                    'max_init_terrain_level', 'curriculum', 'step_height',
                    'terrain_length', 'terrain_width'):
            if hasattr(terrain_cfg, key):
                print('terrain_cfg_%s=%s' % (key, getattr(terrain_cfg, key)), flush=True)

    num_cols = int(origins.shape[1])
    num_rows = int(origins.shape[0])
    max_level = getattr(simulator, '_max_terrain_level', None)
    if torch.is_tensor(max_level):
        max_level = int(max_level.max().item())
    if max_level is None:
        max_level = num_rows - 1
    # The attribute may report the row count instead of the highest index.
    max_level = max(0, min(int(max_level), num_rows - 1))

    mode = str(level_spec).lower()
    if mode == 'off':
        print('terrain_force=skipped reason=disabled', flush=True)
        return None

    if mode == 'matrix':
        matrix_levels = [int(item) for item in os.environ.get('TERRAIN_MATRIX_LEVELS', '4,7,10').split(',') if item.strip()]
        if not matrix_levels:
            matrix_levels = [4, 7, 10]
        index = torch.arange(levels.shape[0], device=levels.device)
        level_table = torch.tensor(matrix_levels, device=levels.device)
        levels[:] = level_table[(index // num_cols) % level_table.shape[0]]
        types[:] = index % num_cols
        camera_level = int(os.environ.get('TERRAIN_CAMERA_LEVEL', '8'))
        camera_type = int(os.environ.get('TERRAIN_CAMERA_TYPE', str(num_cols - 1)))
        levels[0] = max(0, min(camera_level, max_level))
        types[0] = camera_type % num_cols
        level = -1
    elif mode == 'spread':
        levels[:] = torch.arange(levels.shape[0], device=levels.device) % (max_level + 1)
        camera_level = int(os.environ.get('TERRAIN_CAMERA_LEVEL', '4'))
        levels[0] = max(0, min(camera_level, max_level))
        level = -1
    elif mode == 'auto':
        level = max(0, int(round(max_level * 0.6)))
        levels[:] = level
    else:
        level = max(0, min(int(level_spec), max_level))
        levels[:] = level

    if mode != 'matrix':
        if str(type_spec).lower() == 'spread':
            types[:] = torch.arange(types.shape[0], device=types.device) % num_cols
            if num_cols > 1:
                types[0] = num_cols - 1
        else:
            types[:] = int(type_spec) % num_cols
    levels.clamp_(0, max_level)
    types.clamp_(0, num_cols - 1)

    origins_ok = False
    if hasattr(simulator, '_get_env_origins'):
        try:
            simulator._get_env_origins()
            origins_ok = True
            print('terrain_force_origins=repo_get_env_origins', flush=True)
        except Exception as exc:
            print('terrain_force_origin_error=%s' % (repr(exc)[:160],), flush=True)
    if not origins_ok:
        try:
            simulator.env_origins[:] = origins[levels, types].to(
                device=simulator.env_origins.device, dtype=simulator.env_origins.dtype)
            print('terrain_force_origins=manual_assignment', flush=True)
        except Exception as exc:
            print('terrain_force_origin_error=%s' % (repr(exc)[:160],), flush=True)

    # Curriculum must not pull the envs back down to the easy rows.
    for holder, label in ((env, 'env'), (simulator, 'simulator')):
        if hasattr(holder, 'update_terrain_curriculum'):
            try:
                holder.update_terrain_curriculum = lambda *args, **kwargs: None
                print('terrain_curriculum_disabled=%s' % label, flush=True)
            except Exception as exc:
                print('terrain_curriculum_disable_failed=%s error=%s' % (label, repr(exc)[:120]), flush=True)

    print('terrain_force=applied', flush=True)
    print('terrain_force_mode=%s' % mode, flush=True)
    print('terrain_force_level=%s' % ('matrix' if level < 0 else level), flush=True)
    print('terrain_force_max_level=%d' % max_level, flush=True)
    print('terrain_force_cols=%d' % num_cols, flush=True)
    print('terrain_force_levels_min=%d' % int(levels.min().item()), flush=True)
    print('terrain_force_levels_max=%d' % int(levels.max().item()), flush=True)
    print('terrain_force_camera_env_type=%d' % int(types[0].item()), flush=True)
    print('terrain_force_camera_env_level=%d' % int(levels[0].item()), flush=True)
    print('terrain_force_camera_origin_z=%.4f' % float(simulator.env_origins[0, 2].item()), flush=True)

    env_ids = torch.arange(env.num_envs, device=env.device)
    if hasattr(env, 'reset_idx'):
        env.reset_idx(env_ids)
        print('terrain_force_reset=env.reset_idx', flush=True)
    elif hasattr(simulator, 'reset_idx'):
        simulator.reset_idx(env_ids)
        print('terrain_force_reset=simulator.reset_idx', flush=True)
    for name in ('episode_length_buf', 'episode_length'):
        buf = getattr(env, name, None)
        if torch.is_tensor(buf) and buf.shape[0] == env.num_envs:
            buf.zero_()
            print('terrain_force_reset_%s=zeroed' % name, flush=True)
    try:
        spawn = simulator._base_pos[:, 2]
        print('spawn_base_height_min=%.4f mean=%.4f max=%.4f' % (
            float(spawn.min().detach().cpu()),
            float(spawn.mean().detach().cpu()),
            float(spawn.max().detach().cpu())), flush=True)
    except Exception:
        pass
    return level


def main():
    local, _ = parse_args()
    print('stage=python_started', flush=True)
    sys.argv = [
        sys.argv[0], '--task', local.task, '--load_run', local.load_run,
        '--ckpt', str(local.ckpt), '--num_envs', str(local.num_envs),
    ]
    args = get_args()
    args.task = local.task
    args.load_run = local.load_run
    args.ckpt = local.ckpt
    args.checkpoint = local.ckpt
    args.headless = False
    env, _ = task_registry.make_env(name=args.task, args=args)
    print('stage=env_created', flush=True)
    runner, _ = task_registry.make_alg_runner(env=env, name=local.task, args=args)
    print('stage=runner_created', flush=True)
    print('checkpoint_requested=%d' % local.ckpt, flush=True)
    load_policy_weights(runner, local.checkpoint_path, env.device)
    env.add_noise = False
    print('eval_noise=disabled', flush=True)
    force_terrain(env, local.terrain_level, local.terrain_types)
    policy = runner.get_inference_policy(device=env.device)
    obs, obs_history = refresh_policy_observation(env, local.command_x)
    if obs.ndim != 2:
        raise RuntimeError('unexpected policy observation shape: %s' % (tuple(obs.shape),))
    expected_obs = getattr(getattr(getattr(env, 'cfg', None), 'env', None), 'num_observations', None)
    print('observation_shape=%s' % (tuple(obs.shape),), flush=True)
    print('expected_observations=%s' % expected_obs, flush=True)
    history_shape = None if obs_history is None else tuple(obs_history.shape)
    print('observation_history=%s' % (history_shape,), flush=True)
    policy_mode = select_policy_mode(policy, obs.detach(), obs_history, local.num_envs)
    max_episode_length = getattr(env, 'max_episode_length', None)
    if torch.is_tensor(max_episode_length):
        max_episode_length = int(max_episode_length.max().item())
    if max_episode_length is None:
        try:
            cfg_obj = env.cfg
            max_episode_length = int(round(
                cfg_obj.env.episode_length_s / (cfg_obj.control.decimation * cfg_obj.sim.dt)))
        except Exception:
            max_episode_length = 1000
    max_episode_length = int(max_episode_length)
    print('max_episode_length=%d' % max_episode_length, flush=True)
    if expected_obs is not None and obs.shape[1] != int(expected_obs):
        print('warning=observation_width_mismatch expected=%s actual=%s' % (expected_obs, obs.shape[1]), flush=True)

    os.makedirs(local.frame_dir, exist_ok=True)
    os.makedirs(os.path.dirname(local.csv), exist_ok=True)
    simulator = env.simulator
    print('simulator_type=%s' % type(simulator).__name__, flush=True)
    print('simulator_attrs=%s' % ','.join(sorted(name for name in dir(simulator) if not name.startswith('__'))), flush=True)
    gym = getattr(simulator, '_gym', None)
    sim = getattr(simulator, '_sim', None)
    if gym is None or sim is None:
        raise RuntimeError('Isaac Gym handles unavailable on environment')
    camera_env = simulator._envs[0]
    camera_props = gymapi.CameraProperties()
    camera_props.width = 1280
    camera_props.height = 720
    camera_props.horizontal_fov = 70.0
    camera_props.enable_tensors = False
    camera = gym.create_camera_sensor(camera_env, camera_props)
    if camera < 0:
        raise RuntimeError('create_camera_sensor failed')
    episode_reward = torch.zeros(local.num_envs, device=env.device)
    episode_length = torch.zeros(local.num_envs, device=env.device)
    episode_vel_sum = torch.zeros(local.num_envs, device=env.device)
    episode_min_height = torch.full((local.num_envs,), float('inf'), device=env.device)
    episode_start_z = torch.zeros(local.num_envs, device=env.device)
    episode_peak_z = torch.zeros(local.num_envs, device=env.device)
    state_handle = open(local.state_log, 'w', encoding='utf-8')
    state_handle.write('step,command_x,command_y,command_yaw,base_vel_x,base_vel_y,base_ang_vel_z,base_height,roll,pitch,action_min,action_max,action_norm,terrain_relief\n')
    completed = 0
    frame_id = 0
    step_id = 0
    rows = []
    while completed < local.episodes:
        obs, obs_history = refresh_policy_observation(env, local.command_x)
        history_arg = None
        if policy_mode == 'obs_history':
            history_arg = obs_history
        elif policy_mode == 'obs_history_flat':
            history_arg = obs_history.reshape(obs_history.shape[0], -1)
        with torch.no_grad():
            if history_arg is not None:
                actions = policy(obs.detach(), history_arg)
            else:
                actions = policy(obs.detach())
            if isinstance(actions, (list, tuple)):
                actions = actions[0]
        step_out = env.step(actions.detach())
        if not isinstance(step_out, (tuple, list)):
            raise RuntimeError('env.step returned %s' % type(step_out).__name__)
        if len(step_out) >= 7:
            rewards, dones = step_out[4], step_out[5]
        elif len(step_out) == 5:
            rewards, dones = step_out[2], step_out[3]
        else:
            raise RuntimeError('unexpected env.step return length: %d' % len(step_out))
        obs, obs_history = refresh_policy_observation(env, local.command_x)
        episode_reward += rewards
        episode_length += 1
        base_vel_x = simulator._base_lin_vel[:, 0]
        base_vel_y = simulator._base_lin_vel[:, 1]
        base_ang_vel_z = simulator._base_ang_vel[:, 2]
        base_height = simulator._base_pos[:, 2]
        base_euler = simulator._base_euler
        episode_vel_sum += base_vel_x
        episode_min_height = torch.minimum(episode_min_height, base_height)
        fresh = episode_length <= 1
        episode_start_z = torch.where(fresh, base_height, episode_start_z)
        episode_peak_z = torch.where(fresh, base_height, torch.maximum(episode_peak_z, base_height))
        measured = getattr(simulator, 'measured_heights', None)
        if torch.is_tensor(measured) and measured.dim() >= 2:
            relief = float((measured[0].max() - measured[0].min()).detach().cpu())
        else:
            relief = float('nan')
        if step_id % local.state_interval == 0:
            state_handle.write('%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n' % (
                step_id, local.command_x, 0.0, 0.0,
                float(base_vel_x[0].detach().cpu()), float(base_vel_y[0].detach().cpu()),
                float(base_ang_vel_z[0].detach().cpu()), float(base_height[0].detach().cpu()),
                float(base_euler[0, 0].detach().cpu()), float(base_euler[0, 1].detach().cpu()),
                float(actions.min().detach().cpu()), float(actions.max().detach().cpu()),
                float(actions[0].norm().detach().cpu()), relief))
            state_handle.flush()
        if step_id and step_id % 200 == 0:
            current_levels = getattr(simulator, '_terrain_levels', None)
            if current_levels is not None:
                print('terrain_level_check_step=%d min=%d max=%d' % (
                    step_id,
                    int(current_levels.min().item()),
                    int(current_levels.max().item())), flush=True)
        step_id += 1
        base_pos = simulator._base_pos[0].detach().cpu()
        gym.set_camera_location(
            camera, camera_env,
            gymapi.Vec3(float(base_pos[0] - 3.8), float(base_pos[1] - 3.2), float(base_pos[2] + 2.0)),
            gymapi.Vec3(float(base_pos[0] + 2.0), float(base_pos[1]), float(base_pos[2] + 0.1)),
        )
        gym.render_all_camera_sensors(sim)
        if frame_id < local.frames:
            frame_path = os.path.join(local.frame_dir, 'frame-%06d.png' % frame_id)
            gym.write_camera_image_to_file(sim, camera_env, camera, gymapi.IMAGE_COLOR, frame_path)
            frame_id += 1
        done_ids = torch.nonzero(dones, as_tuple=False).flatten().tolist()
        for index in done_ids:
            if completed >= local.episodes:
                break
            row = {
                'episode': completed,
                'env_id': index,
                'return': float(episode_reward[index].detach().cpu()),
                'length': int(episode_length[index].detach().cpu()),
                'done': 1,
                'command_x_forced': local.command_x,
                'command_x_observed': float(env.commands[index, 0].detach().cpu()),
                'mean_base_vel_x': float((episode_vel_sum[index] / episode_length[index]).detach().cpu()),
                'min_base_height': float(episode_min_height[index].detach().cpu()),
                'base_z_delta': float((base_height[index] - episode_start_z[index]).detach().cpu()),
                'base_z_peak': float((episode_peak_z[index] - episode_start_z[index]).detach().cpu()),
            }
            row['command_x'] = local.command_x
            if hasattr(env, 'base_lin_vel'):
                row['base_vel_x'] = tensor_mean(env.base_lin_vel, index)
            terrain_levels = getattr(simulator, '_terrain_levels', None)
            if terrain_levels is None:
                terrain_levels = getattr(simulator, 'terrain_levels', None)
            if terrain_levels is not None:
                row['terrain_level'] = tensor_mean(terrain_levels, index)
            terrain_types = getattr(simulator, '_terrain_types', None)
            if terrain_types is None:
                terrain_types = getattr(simulator, 'terrain_types', None)
            if terrain_types is not None:
                row['terrain_type'] = tensor_mean(terrain_types, index)
            rows.append(row)
            completed += 1
            episode_reward[index] = 0
            episode_length[index] = 0
            episode_vel_sum[index] = 0
            episode_min_height[index] = float('inf')

    state_handle.close()
    fields = sorted({key for row in rows for key in row})
    with open(local.csv, 'w', newline='', encoding='utf-8') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    returns = [row['return'] for row in rows]
    lengths = [row['length'] for row in rows]
    forward = [row['mean_base_vel_x'] for row in rows]
    heights = [row['min_base_height'] for row in rows]
    mean_forward = sum(forward) / len(forward)
    mean_min_height = sum(heights) / len(heights)
    tracking_ratio = mean_forward / local.command_x if local.command_x else 0.0
    pass_count = sum(1 for value in lengths if value >= max_episode_length - 1)
    pass_rate = pass_count / len(lengths)
    terrain_values = [row['terrain_level'] for row in rows if 'terrain_level' in row]
    mean_terrain_level = sum(terrain_values) / len(terrain_values) if terrain_values else None
    gate = 'pass' if (mean_forward >= 0.5 * local.command_x and mean_min_height >= 0.20) else 'fail'
    level_groups = {}
    for row in rows:
        if 'terrain_level' not in row:
            continue
        key = int(round(row['terrain_level']))
        level_groups.setdefault(key, []).append(row)
    cell_groups = {}
    for row in rows:
        if 'terrain_level' not in row or 'terrain_type' not in row:
            continue
        cell = (int(round(row['terrain_type'])), int(round(row['terrain_level'])))
        cell_groups.setdefault(cell, []).append(row)
    with open(local.summary, 'w', encoding='utf-8') as handle:
        handle.write('task=%s\n' % local.task)
        handle.write('checkpoint=%d\n' % local.ckpt)
        handle.write('checkpoint_path=%s\n' % local.checkpoint_path)
        handle.write('command_x=%.6f\n' % local.command_x)
        handle.write('episodes=%d\n' % len(rows))
        handle.write('max_episode_length=%d\n' % max_episode_length)
        handle.write('mean_return=%.6f\n' % (sum(returns) / len(returns)))
        handle.write('mean_length=%.6f\n' % (sum(lengths) / len(lengths)))
        handle.write('mean_base_vel_x=%.6f\n' % mean_forward)
        handle.write('speed_tracking_error=%.6f\n' % abs(local.command_x - mean_forward))
        handle.write('mean_min_base_height=%.6f\n' % mean_min_height)
        handle.write('mean_tracking_ratio=%.6f\n' % tracking_ratio)
        handle.write('pass_rate=%.6f\n' % pass_rate)
        handle.write('fall_rate=%.6f\n' % (1.0 - pass_rate))
        if mean_terrain_level is not None:
            handle.write('mean_terrain_level=%.6f\n' % mean_terrain_level)
        handle.write('behavior_gate=%s\n' % gate)
        z_deltas = [row['base_z_delta'] for row in rows if 'base_z_delta' in row]
        z_peaks = [row['base_z_peak'] for row in rows if 'base_z_peak' in row]
        if z_deltas:
            handle.write('mean_base_z_delta=%.6f\n' % (sum(z_deltas) / len(z_deltas)))
            handle.write('max_base_z_peak=%.6f\n' % max(z_peaks))
        for key in sorted(level_groups):
            group = level_groups[key]
            group_pass = sum(1 for row in group if row['length'] >= max_episode_length - 1) / len(group)
            group_vel = sum(row['mean_base_vel_x'] for row in group) / len(group)
            handle.write('level_%d_episodes=%d\n' % (key, len(group)))
            handle.write('level_%d_pass_rate=%.6f\n' % (key, group_pass))
            handle.write('level_%d_mean_base_vel_x=%.6f\n' % (key, group_vel))
        for cell in sorted(cell_groups):
            group = cell_groups[cell]
            group_pass = sum(1 for row in group if row['length'] >= max_episode_length - 1) / len(group)
            group_vel = sum(row['mean_base_vel_x'] for row in group) / len(group)
            handle.write('type_%d_level_%d_episodes=%d\n' % (cell[0], cell[1], len(group)))
            handle.write('type_%d_level_%d_pass_rate=%.6f\n' % (cell[0], cell[1], group_pass))
            handle.write('type_%d_level_%d_mean_base_vel_x=%.6f\n' % (cell[0], cell[1], group_vel))
    if frame_id:
        subprocess.run([
            'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
            '-framerate', str(local.fps), '-i', os.path.join(local.frame_dir, 'frame-%06d.png'),
            '-frames:v', str(frame_id), '-c:v', 'libx264', '-pix_fmt', 'yuv420p', local.video,
        ], check=True)
    print('eval_episodes=%d' % len(rows))
    print('eval_mean_base_vel_x=%.6f' % mean_forward)
    print('eval_mean_min_base_height=%.6f' % mean_min_height)
    print('behavior_gate=%s' % gate)
    print('eval_csv_ready=%s' % local.csv)
    print('eval_video_ready=%s' % local.video)


if __name__ == '__main__':
    main()
