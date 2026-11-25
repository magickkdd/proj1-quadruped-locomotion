import argparse
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
    parser.add_argument('--ckpt', type=int, default=1500)
    parser.add_argument('--frames', type=int, default=900)
    parser.add_argument('--fps', type=int, default=30)
    parser.add_argument('--out_dir', required=True)
    parser.add_argument('--video', required=True)
    return parser.parse_known_args()


def main():
    local, _ = parse_args()
    sys.argv = [
        sys.argv[0],
        '--task', local.task,
        '--load_run', local.load_run,
        '--ckpt', str(local.ckpt),
        '--headless',
        '--num_envs', '1',
    ]
    args = get_args()
    args.task = local.task
    args.load_run = local.load_run
    args.checkpoint = local.ckpt
    args.headless = True
    env, env_cfg = task_registry.make_env(name=args.task, args=args)
    runner, _ = task_registry.make_alg_runner(env=env, name=args.task, args=args)
    policy = runner.get_inference_policy(device=env.device)
    obs = env.get_observations()

    os.makedirs(local.out_dir, exist_ok=True)
    gym = env.gym
    sim = env.sim
    camera_props = gymapi.CameraProperties()
    camera_props.width = 1280
    camera_props.height = 720
    camera_props.horizontal_fov = 70.0
    camera_props.enable_tensors = False
    camera_env = env.envs[0]
    camera = gym.create_camera_sensor(camera_env, camera_props)
    if camera < 0:
        raise RuntimeError('create_camera_sensor failed')

    origin = env.env_origins[0].detach().cpu()
    camera_pos = gymapi.Vec3(float(origin[0] + 3.2), float(origin[1] - 3.2), 1.8)
    camera_target = gymapi.Vec3(float(origin[0]), float(origin[1]), 0.45)
    gym.set_camera_location(camera, camera_env, camera_pos, camera_target)

    for frame_id in range(local.frames):
        with torch.no_grad():
            actions = policy(obs.detach())
        obs, _, _, _, _ = env.step(actions)
        gym.render_all_camera_sensors(sim)
        frame_path = os.path.join(local.out_dir, 'frame-%06d.png' % frame_id)
        gym.write_camera_image_to_file(sim, camera_env, camera, gymapi.IMAGE_COLOR, frame_path)

    subprocess.run([
        'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
        '-framerate', str(local.fps), '-i', os.path.join(local.out_dir, 'frame-%06d.png'),
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', local.video,
    ], check=True)
    print('camera_video_ready=%s' % local.video)


if __name__ == '__main__':
    main()
