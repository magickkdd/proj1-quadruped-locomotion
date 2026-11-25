# Unitree Go2 复杂地形鲁棒运动控制（Isaac Gym 仿真）

基于 `LeggedGym-Ex` + `Isaac Gym Preview 4` 复现并改造 Unitree Go2 的四足强化学习训练链路：
环境自举、PPO 训练、地形课程、域随机化、checkpoint 评测、连续地形行走录制。

> 全部结果均为 **Isaac Gym 纯仿真**，未做真机部署。

## 当前状态

| 能力 | 状态 | 证据 |
|---|---|---|
| 平地稳定行走 | ✅ 已通过 | `results/flat-walk/`：20/20 episode 满 1000 步，平均速度 0.266 m/s（指令 0.3），最低机身高度 0.351 m |
| 粗糙地形训练 | ⚠️ 可训练、可评测 | `results/rough-8000/`：8000 迭代，4096 环境，约 7.9 亿环境步 |
| 粗糙地形稳定通过 | ❌ 未达标 | 同上：平均 episode 长度 290/1000，摔倒率 100% |
| 阶梯连续攀爬 | ❌ 未达标 | `results/level-sweep/`：10 类地形从第 0 档连续走，最远 39.5 m，多数在 2~20 m 内摔倒 |
| Walk These Ways 配置 | ⏳ 已打包待训 | `scripts/train_wtw_job.sh` |

结论直说：**平地行走链路已经打通并可复现；复杂地形仍处在“能训、能评、不稳定”的阶段。**

## 技术栈

| 项 | 版本 |
|---|---|
| 仿真器 | Isaac Gym Preview 4（`isaacgym` 1.0rc4） |
| 算法库 | rsl_rl（PPO，teacher-student / privileged 变体） |
| 训练框架 | LeggedGym-Ex，固定 commit `09283fe0e768274feb79eacacd72f1dd4175c142` |
| Python | 3.8（conda-pack 打包） |
| PyTorch | 2.4.1+cu121 |
| GPU | NVIDIA A100-SXM4-80GB |
| 并行环境 | 4096（评测 1~30） |

本仓库 **不包含** LeggedGym-Ex 源码，请按上面的 commit 自行 clone；也不包含 Isaac Gym 安装包。

## 目录结构

```text
proj1-quadruped-locomotion/
├── docs/
│   ├── 01-spec.md                 # 项目规格与边界
│   ├── 02-approach.md             # 技术路线与仓库选型
│   ├── 03-platform-adaptation.md  # 训练平台资源与环境适配
│   ├── 04-flat-baseline-notes.md  # 平地基线记录
│   └── 05-debug-log.md            # 故障排查记录（现象→证据→根因→修复）
├── scripts/                       # 训练、评测、录制、环境自举
├── configs/                       # Go2 训练配置快照
├── results/                       # 各轮运行的日志、CSV、summary
├── media/                         # 评测视频索引（视频文件本身在 Hugging Face）
└── packages/                      # 可提交训练的整合包索引
```

## 快速开始

平台侧只需要一条命令，代码包上传后自动解压到 `/code/workspace`：

```bash
# 平地策略训练 + 评测 + 录制
bash /code/workspace/scripts/train_eval_record_job.sh

# Walk These Ways 粗糙地形训练 + 连续地形评测
bash /code/workspace/scripts/train_wtw_job.sh

# 只用已有 checkpoint 做连续地形评测
bash /code/workspace/scripts/eval_level_sweep_entry.sh
```

产物统一落在：

```text
/data/proj1/runs/<run_id>/           # checkpoint、每阶段训练日志
/data/proj1/results/<run_id>.log     # 主日志
/data/proj1/media/<run_id>/          # 视频、CSV
```

## 评测协议

1. 锁定地形列（10 类地形）与起始档位（第 0 档）
2. 指令固定 0.4 m/s，沿 +X 连续行进（+X 即难度递增方向）
3. 横向纠偏保持在当前地形列内，越界或摔倒立即终止
4. 记录 `distance_x`、`reached_row`、`max_lateral_dev`、`exit_reason`

这套协议来自对仓库源码的核对：`env_origin_x = (row + 0.5) * 8 m`，`step_height = 0.05 + 0.2 * difficulty`，`difficulty = row / 10`。

## 地形构成

配置 `terrain_proportions = [0.2, 0.1, 0.25, 0.25, 0.2]`，10 列映射为：

| 列 | 地形 |
|---|---|
| 0、1 | 平滑斜坡（两个方向） |
| 2 | 随机起伏 |
| 3、4、5 | 楼梯（一个方向） |
| 6、7 | 楼梯（另一个方向） |
| 8、9 | 离散障碍块 |

每列有 10 个难度档，第 0 档最简单（5 cm 台阶 / 0° 坡），第 9 档最难（23 cm 台阶 / 20.6° 坡）。

## 主要结果

**平地行走（已验证）**

```text
checkpoint: model_3000.pt
episodes: 20, 全部满 1000 步
mean_base_vel_x: 0.266 m/s (指令 0.3)
mean_min_base_height: 0.351 m
tracking_ratio: 0.886
behavior_gate: pass
```

**粗糙地形 8000 迭代（能力上限基线）**

```text
task: go2_ts, 4096 envs, 8000 iters ≈ 7.9 亿环境步
mean episode length: 290 / 1000
fall_rate: 100%
连续行走距离: 斜坡 35~40 m，起伏 19 m，楼梯 6~31 m
```

**关键发现**：训练奖励正常（`tracking_lin_vel ≈ 0.90`、episode 长度 987）但评测立刻摔倒，
根因是评测端没有真正加载 checkpoint，以及地形课程阈值对称导致随机游走。详见 `docs/05-debug-log.md`。

## 资产

- 视频与 checkpoint 体积较大，托管在 Hugging Face：**https://huggingface.co/A2bao/go2-quadruped-locomotion**（视频在 `videos/` 目录）
- 视频与测试条件的对照表见 `media/INDEX.md`
- 可提交训练的整合包见 `packages/INDEX.md`

## 免责声明

结果仅限 Isaac Gym 仿真环境，未做 sim-to-real 验证。
