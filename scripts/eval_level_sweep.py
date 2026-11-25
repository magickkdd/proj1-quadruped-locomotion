"""Walk one terrain column continuously from difficulty row 0 upward.

For every terrain type the robot spawns on row 0 and is commanded to walk
along +X, which is exactly how the terrain grid orders difficulty. One video
and one metric row are produced per terrain type.
"""
import argparse
import csv
import inspect
import os
import subprocess
import sys

import isaacgym  # noqa: F401
from isaacgym import gymapi
import torch

from legged_gym.envs import *  # noqa: F401,F403
from legged_gym.utils import get_args, task_registry

TERRAIN_LABELS = {
    0: 'slope_a',
    1: 'slope_b',
    2: 'rough',
    3: 'stairs_a',
    4: 'stairs_a',
    5: 'stairs_a',
    6: 'stairs_b',
    7: 'stairs_b',
    8: 'discrete',
    9: 'discrete',
}


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('--task', default='go2_ts')
    parser.add_argument('--load_run', required=True)
    parser.add_argument('--ckpt', type=int, required=True)
    parser.add_argument('--checkpoint_path', default=os.environ.get('CHECKPOINT_PATH', ''))
    parser.add_argument('--command_x', type=float, default=0.4)
    parser.add_argument('--max_steps', type=int, default=12000)
    parser.add_argument('--frame_stride', type=int, default=5)
    parser.add_argument('--fps', type=int, default=20)
    parser.add_argument('--out_dir', required=True)
    parser.add_argument('--types', default='0,1,2,3,4,5,6,7,8,9')
    parser.add_argument('--level', type=int, default=int(os.environ.get('TERRAIN_LEVEL', '0')))
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
    raise RuntimeError('cannot locate actor-critic on runner')


def verify_weights(actor_critic, state_dict):
    matched = 0
    with torch.no_grad():
        for name, parameter in actor_critic.named_parameters():
            stored = state_dict.get(name)
            if not torch.is_tensor(stored) or tuple(stored.shape) != tuple(parameter.shape):
                continue
            if torch.allclose(parameter.detach().cpu(), stored.detach().float().cpu()):
                matched += 1
    return matched


def load_policy_weights(runner, checkpoint_path):
    if not checkpoint_path or not os.path.isfile(checkpoint_path):
        raise RuntimeError('checkpoint not found: %s' % checkpoint_path)
    payload = torch_load_checkpoint(checkpoint_path, 'cpu')
    state_dict = payload.get('model_state_dict', payload) if isinstance(payload, dict) else payload
    actor_critic = locate_actor_critic(runner)
    try:
        runner.load(checkpoint_path, load_optimizer=False)
    except Exception:
        pass
    matched = verify_weights(actor_critic, state_dict)
    if matched == 0:
        actor_critic.load_state_dict(state_dict, strict=False)
        matched = verify_weights(actor_critic, state_dict)
    if matched == 0:
        raise RuntimeError('checkpoint weights were not applied: %s' % checkpoint_path)
    print('checkpoint_matched_tensors=%d' % matched, flush=True)


def read_observation(env):
    raw = env.get_observations()
    if torch.is_tensor(raw):
        return raw, None
    tensors = [item for item in raw if torch.is_tensor(item)]
    obs = tensors[0]
    history = tensors[1] if len(tensors) > 1 else None
    for name in ('obs_history_buf', 'obs_history'):
        candidate = getattr(env, name, None)
        if torch.is_tensor(candidate):
            history = candidate
            break
    return obs, history


def select_policy_mode(policy, obs, history):
    try:
        positional = [p for p in inspect.signature(policy).parameters.values()
                      if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)]
    except (TypeError, ValueError):
        positional = []
    if len(positional) >= 2 and history is not None:
        print('policy_call_mode=obs_history', flush=True)
        return 'obs_history'
    print('policy_call_mode=obs_only', flush=True)
    return 'obs_only'


def force_command(env, command_x, command_y=0.0):
    env.commands[:, 0] = command_x
    if env.commands.shape[1] > 1:
        env.commands[:, 1] = command_y
    for index in range(2, env.commands.shape[1]):
        env.commands[:, index] = 0.0


def refresh(env, command_x, command_y=0.0):
    force_command(env, command_x, command_y)
    env.compute_observations()
    return read_observation(env)


def pin(env, level, terrain_type):
    sim = env.simulator
    sim._terrain_levels[:] = level
    sim._terrain_types[:] = terrain_type
    env._update_terrain_curriculum = lambda *args, **kwargs: None
    sim.update_terrain_curriculum = lambda *args, **kwargs: None
    sim._env_origins[:] = sim._terrain_origins[sim._terrain_levels, sim._terrain_types]
    env_ids = torch.arange(env.num_envs, device=env.device)
    env.reset_idx(env_ids)
    if hasattr(env, 'episode_length_buf'):
        env.episode_length_buf.zero_()
    # clean, reproducible spawn: no random xy offset, no initial velocity
    try:
        base_pos = sim._base_init_pos.reshape(1, 3) + sim._env_origins[:1]
        base_quat = sim._base_init_quat.reshape(1, 4).repeat(env.num_envs, 1)
        zeros = torch.zeros((env.num_envs, 3), device=env.device)
        sim.reset_root_states(env_ids, base_pos.repeat(env.num_envs, 1), base_quat, zeros, zeros)
    except Exception as exc:
        print('clean_spawn_skipped=%s' % (repr(exc)[:120],), flush=True)


def main():
    local, _ = parse_args()
    sys.argv = [sys.argv[0], '--task', local.task, '--load_run', local.load_run,
                '--ckpt', str(local.ckpt), '--num_envs', '1']
    args = get_args()
    args.task = local.task
    args.load_run = local.load_run
    args.ckpt = local.ckpt
    args.checkpoint = local.ckpt
    args.num_envs = 1
    args.headless = False

    env, _ = task_registry.make_env(name=args.task, args=args)
    print('stage=env_created', flush=True)
    runner, _ = task_registry.make_alg_runner(env=env, name=local.task, args=args)
    load_policy_weights(runner, local.checkpoint_path)
    env.add_noise = False
    env.max_episode_length = local.max_steps
    policy = runner.get_inference_policy(device=env.device)

    obs, history = refresh(env, local.command_x)
    mode = select_policy_mode(policy, obs.detach(), history)

    sim = env.simulator
    gym = sim._gym
    sim_handle = sim._sim
    camera_env = sim._envs[0]
    camera_props = gymapi.CameraProperties()
    camera_props.width = 1280
    camera_props.height = 720
    camera_props.horizontal_fov = 70.0
    camera_props.enable_tensors = False
    camera = gym.create_camera_sensor(camera_env, camera_props)
    if camera < 0:
        raise RuntimeError('create_camera_sensor failed')

    os.makedirs(local.out_dir, exist_ok=True)
    rows = []
    types = [int(item) for item in local.types.split(',') if item.strip()]

    for terrain_type in types:
        label = TERRAIN_LABELS.get(terrain_type, 'type_%d' % terrain_type)
        print('stage=terrain_start terrain_type=%d label=%s level=%d' % (terrain_type, label, local.level), flush=True)
        pin(env, local.level, terrain_type)
        obs, history = refresh(env, local.command_x)
        start_x = float(sim._root_states[0, 0].item())
        start_z = float(sim._root_states[0, 2].item())
        print('spawn_x=%.3f spawn_z=%.3f' % (start_x, start_z), flush=True)
        frame_dir = os.path.join(local.out_dir, 'frames_type_%d_level_%d' % (terrain_type, local.level))
        os.makedirs(frame_dir, exist_ok=True)
        video_path = os.path.join(local.out_dir, 'terrain_%d_%s_level_%d.mp4' % (terrain_type, label, local.level))

        frames = 0
        steps = 0
        vel_sum = 0.0
        max_x = start_x
        min_height = float('inf')
        fell = 0
        exit_reason = 'timeout'
        y_center = (terrain_type + 0.5) * 8.0
        max_lateral = 0.0
        steer_gain = 1.2
        while steps < local.max_steps:
            y_now = float(sim._base_pos[0, 1].item())
            lateral = y_now - y_center
            max_lateral = max(max_lateral, abs(lateral))
            command_y = max(-0.3, min(0.3, -steer_gain * lateral))
            obs, history = refresh(env, local.command_x, command_y)
            hist_arg = history if mode == 'obs_history' else None
            with torch.no_grad():
                actions = policy(obs.detach(), hist_arg) if hist_arg is not None else policy(obs.detach())
                if isinstance(actions, (list, tuple)):
                    actions = actions[0]
            step_out = env.step(actions.detach())
            if len(step_out) >= 7:
                rewards, dones = step_out[4], step_out[5]
            else:
                rewards, dones = step_out[2], step_out[3]
            steps += 1
            x_now = float(sim._base_pos[0, 0].item())
            y_now = float(sim._base_pos[0, 1].item())
            z_now = float(sim._base_pos[0, 2].item())
            vel_sum += float(sim._base_lin_vel[0, 0].item())
            max_x = max(max_x, x_now)
            min_height = min(min_height, z_now)
            max_lateral = max(max_lateral, abs(y_now - y_center))
            if steps % local.frame_stride == 0 and frames < 4000:
                base_pos = sim._base_pos[0].detach().cpu()
                gym.set_camera_location(
                    camera, camera_env,
                    gymapi.Vec3(float(base_pos[0] - 3.8), float(base_pos[1] - 3.2), float(base_pos[2] + 2.0)),
                    gymapi.Vec3(float(base_pos[0] + 2.0), float(base_pos[1]), float(base_pos[2] + 0.1)),
                )
                gym.render_all_camera_sensors(sim_handle)
                gym.write_camera_image_to_file(
                    sim_handle, camera_env, camera, gymapi.IMAGE_COLOR,
                    os.path.join(frame_dir, 'frame-%06d.png' % frames))
                frames += 1
            if bool(dones[0].item()):
                fell = 1
                exit_reason = 'fall'
                break
            if abs(y_now - y_center) > 3.5:
                exit_reason = 'off_track'
                break
            if x_now > 79.0 or x_now < 1.0:
                exit_reason = 'boundary'
                break
        if frames:
            subprocess.run([
                'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
                '-framerate', str(local.fps), '-i', os.path.join(frame_dir, 'frame-%06d.png'),
                '-frames:v', str(frames), '-c:v', 'libx264', '-pix_fmt', 'yuv420p', video_path,
            ], check=False)
        end_z = float(sim._base_pos[0, 2].item())
        row = {
            'terrain_type': terrain_type,
            'level': local.level,
            'label': label,
            'steps': steps,
            'distance_x': round(max_x - start_x, 3),
            'reached_row': min(9, int(max(0.0, (max_x - start_x)) // 8.0)),
            'z_delta': round(end_z - start_z, 3),
            'min_base_height': round(min_height, 3),
            'mean_vel_x': round(vel_sum / max(1, steps), 3),
            'max_lateral_dev': round(max_lateral, 3),
            'fell': fell,
            'exit_reason': exit_reason,
            'video': video_path,
        }
        rows.append(row)
        print('stage=terrain_done terrain_type=%d distance=%.2f reached_row=%d fell=%d ' % (
            terrain_type, row['distance_x'], row['reached_row'], fell) +
            'lateral=%.2f exit=%s video=%s' % (row['max_lateral_dev'], exit_reason, video_path), flush=True)

    csv_path = os.path.join(local.out_dir, 'level_sweep.csv')
    with open(csv_path, 'w', newline='', encoding='utf-8') as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()) if rows else ['terrain_type'])
        writer.writeheader()
        writer.writerows(rows)
    print('level_sweep_csv=%s' % csv_path, flush=True)
    for row in rows:
        print('result terrain=%d label=%s reached_row=%d distance=%.2f lateral=%.2f fell=%d exit=%s' % (
            row['terrain_type'], row['label'], row['reached_row'], row['distance_x'],
            row['max_lateral_dev'], row['fell'], row['exit_reason']), flush=True)


if __name__ == '__main__':
    main()
