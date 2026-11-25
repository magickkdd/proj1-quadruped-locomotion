---
tags:
- reinforcement-learning
- robotics
- isaac-gym
---

# Unitree Go2 平地 PPO 基线

这批文件来自 Intern Discovery 单张 A100-SXM4-80GB 上运行的 `go2-flat-baseline-20261122-140507`。使用 LeggedGym-Ex `09283fe0e768274feb79eacacd72f1dd4175c142` 和 Isaac Gym Preview 4。仅仿真，未进行真机验证。[项目代码](https://github.com/magickkdd/proj_1)

| 训练记录 | 数值 |
|---|---:|
| 并行环境数 | 4,096 |
| PPO 迭代数 | 1,500 |
| 总环境步数 | 147,456,000 |
| 采样与学习累计耗时 | 1,552.96 秒 |
| 最后一轮吞吐 | 94,369 steps/s |
| 最后一轮平均奖励 | 32.37 |

`model_1500.pt` 是最终训练 checkpoint，不是独立导出的推理策略。`checkpoints/` 包含中间 checkpoint，`tensorboard/` 包含训练事件文件，`config/` 包含运行记录和上游训练配置快照。奖励是训练日志统计，不是独立评测结果。

此归档不包含回放视频、独立策略文件或粗糙地形结果。文件校验值见 `SHA256SUMS`。
