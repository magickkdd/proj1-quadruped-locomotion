# 项目总结

## 项目目标

在 A100 训练任务上复现 Unitree Go2 的四足强化学习运动控制链路，覆盖环境搭建、训练、checkpoint 管理、统一评测、视频录制和结果归档。

## 完整流程

```text
平台探测
→ Python / PyTorch / Isaac Gym 环境自举
→ 固定 LeggedGym-Ex 版本
→ 平地基线训练
→ 训练 checkpoint 评测与录制
→ 粗糙地形与课程学习训练
→ 统一地形矩阵评测
→ 故障定位与脚本修复
→ 日志、CSV、视频和配置归档
```

## 过程结果

### 1. 早期失败

训练日志中的 reward、episode length 和速度跟踪项看起来正常，但视频显示 Go2 下沉、坐下或停在原地。不同 checkpoint 的评测轨迹还出现完全相同的情况。

定位结果：评测脚本创建了 runner，却没有显式加载 checkpoint，实际使用的是随机初始化网络。修复后增加参数级权重匹配检查，`checkpoint_matched_tensors=0` 时直接终止评测。

### 2. 平地验证通过

修复 checkpoint 加载、command 与 observation 同步、episode 计数和评测 reset 后，平地策略通过 20 个 episode 的行为门槛：

```text
20/20 episodes completed
mean_base_vel_x = 0.266 m/s
command_x = 0.3 m/s
mean_min_base_height = 0.351 m
behavior_gate = pass
```

### 3. 粗糙地形 8000 迭代

`go2_ts` 使用 4096 个并行环境训练 8000 次迭代，约 7.9 亿环境步。训练阶段的 episode length 约 987、线速度跟踪奖励约 0.90，说明训练闭环本身正常。

统一连续行走评测显示：斜坡可达到约 35～40 m，随机起伏约 19 m，楼梯约 6～31 m，离散障碍约 16～19 m。不同地形之间差异明显，部分环境会卡住或摔倒。

结论：该策略已经能在多类复杂地形上行走，但还不能称为“几乎不摔”的全地形鲁棒策略。8000 迭代结果停止作为当前基线，后续不继续投入同一套 PPO 课程方案。

## 主要试错与修复

| 阶段 | 问题 | 修复 |
|---|---|---|
| 环境 | Isaac Gym 包格式、动态库、导入顺序和日志过长 | 兼容 tar/tar.gz，修复 `LD_LIBRARY_PATH`，先导入 `isaacgym`，关闭进度条 |
| 训练 | 续训参数错误、整合包误跑 100 次迭代 | 使用 `--ckpt`，显式传递 `MAX_ITERATIONS` 并加入最低迭代检查 |
| 评测 | 随机权重、command 不进 observation、teacher-student 输入不一致 | 显式加载并校验 checkpoint，重算 observation，记录 policy 输入形状 |
| 地形 | 负索引、出生点错位、课程等级漂移 | clamp 地形等级，使用仓库出生点逻辑，增加 spawn 与 terrain level 诊断 |
| 指标 | episode 计数未清零、跑出地形列、通过率误判 | 动态读取 episode 上限，越界即停，记录 `exit_reason` |
| 视频 | Xvfb 捕获黑屏、相机不跟随 | 改用 Isaac Gym camera sensor，逐帧保存 PNG 后合成 MP4 |

## 最终资产

- 代码与文档：GitHub 仓库
- 原始 MP4、平地验证视频和复杂地形视频：Hugging Face
- 训练日志、CSV、summary 和配置快照：`results/` 与 `configs/`
- 复现实验包和 SHA256：`packages/INDEX.md`

## 项目边界

本项目验证的是仿真训练和评测工程能力，不包含真机部署、真实传感器噪声验证或面向 SOTA 的公平 benchmark。后续方向转向 HIM、HACL、ABS 等带历史适应、内部模型或安全约束的近期方法。
