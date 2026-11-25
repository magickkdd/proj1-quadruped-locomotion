# 脚本说明

## 环境

| 脚本 | 用途 |
|---|---|
| `bootstrap_env.sh` | A100 上自举 Python 3.8 + PyTorch 2.4.1 + Isaac Gym 环境，输出 `isaacgym-py38.tar.gz` |
| `probe_env.sh` | 探测 GPU、驱动、磁盘、apt 依赖、Xvfb、ffmpeg |

## 训练

| 脚本 | 用途 |
|---|---|
| `train.sh` | 通用训练入口，支持 `--resume` 续训 |
| `train_job.sh` | 单次训练任务包装（解包环境、链接日志、执行训练） |
| `train_eval_record_job.sh` | 平地训练 + 评测 + 录制一体化 |
| `train_rough_curriculum_v2_job.sh` | 粗糙地形课程训练 + 矩阵评测一体化 |
| `train_wtw.py` | Walk These Ways 训练驱动，初始地形行均匀铺满 0~9 |
| `train_wtw_job.sh` | Walk These Ways 训练 + 连续地形评测一体化 |
| `train_stage.py` | 单档位钉死训练驱动，禁用内置课程 |
| `staged_curriculum_job.sh` | 0→9 分档达标训练，达标才升级 |

## 评测与录制

| 脚本 | 用途 |
|---|---|
| `eval_level_sweep.py` | 主评测脚本：每类地形从指定档位沿 +X 连续行走，输出指标与视频 |
| `eval_level_sweep_job.sh` | 评测任务包装（Xvfb、ffmpeg、环境解包） |
| `eval_level_sweep_entry.sh` | 自动定位 run 与 checkpoint 的评测入口 |
| `eval_level_compare_job.sh` | 同一 checkpoint 在第 9 档与第 0 档对比，用于判定档位方向 |
| `eval_and_record.py` | 早期评测脚本：固定档位、固定 episode 数、相机跟随录制 |
| `eval_and_record_job.sh` | 早期评测任务包装 |
| `eval_stair_capability_job.sh` | 台阶能力曲线（已被 level sweep 取代） |
| `camera_play.py` / `camera_*_job.sh` | 纯回放录制（早期方案，已被评测内录制取代） |

## 诊断

| 脚本 | 用途 |
|---|---|
| `diagnostic_flat_speed_sweep.sh` | 三档速度诊断 |
| `diagnostic_checkpoint_speed_sweep.sh` | 多 checkpoint × 多速度诊断 |
| `dump_source_job.sh` | 导出仓库源码与课程相关代码位置 |
| `go2_flat_patch.py` / `patch_terrain_curriculum.py` | 运行时配置补丁（关闭随机化、修改课程初始档位） |

## 约定

- 所有脚本通过 `DATA_ROOT`（默认 `/data/proj1`）定位持久化目录
- 日志写入 `/data/proj1/results/`，视频与 CSV 写入 `/data/proj1/media/`
- 训练 headless，评测需要 `headless=False` + Xvfb 才能创建相机传感器
