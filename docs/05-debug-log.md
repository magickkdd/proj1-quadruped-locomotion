# 故障排查记录

每条都按「现象 → 证据 → 根因 → 修复」记录。这些是本项目最主要的工程工作量，也是复现时最容易踩的坑。

## 1. 评测视频里 Go2 开局下沉、坐下、不前进

- **现象**：训练日志 `Mean reward 32~33`、`Mean episode length 1000`、`rew_tracking_lin_vel 0.96`，但评测视频里机器人 0.6 秒内从 0.39 m 沉到 0.26 m，随后几乎静止。
- **证据**：`action_norm ≈ 0.21`，且动作分布极小（`action_min=-0.105, action_max=+0.092`）；不同 checkpoint（400/1000/1500）评测轨迹逐行完全相同。
- **根因**：`task_registry.make_alg_runner()` 只构造 runner 和**随机初始化**的网络，不会加载 checkpoint。评测脚本直接调用 `get_inference_policy()`，实际一直在用随机权重。
- **修复**：显式 `runner.load(checkpoint_path)`，并逐参数比对内存网络与 checkpoint 文件，输出 `checkpoint_matched_tensors`；为 0 时报错退出，不再生成假的评测结果。

## 2. 评测时 command 写入了环境但策略拿不到

- **现象**：`command_x_forced=0.3`，但日志里 `command_x_observed=0.0`。
- **根因**：只改了 `env.commands`，没有重新计算 observation，策略仍读到旧命令。
- **修复**：改完命令后立即 `env.compute_observations()` 并重新读取观测，不再假设命令位于 `obs[:, :3]`。

## 3. manifest 里 `train_envs=20`

- **现象**：8192 环境训练的 run，manifest 却写 `train_envs=20`。
- **根因**：评测阶段把 `NUM_ENVS` 改成 20 后才写 manifest，写入的是评测环境数。
- **修复**：训练阶段单独记录 `USED_TRAIN_ENVS`，manifest 区分 `requested_train_envs` / `actual_train_envs` / `eval_envs`。

## 4. 续训失败：`unrecognized arguments: --checkpoint 1500`

- **根因**：仓库实际参数是 `--ckpt`，脚本写成了 `--checkpoint`。
- **修复**：统一改为 `--resume --load_run <run> --ckpt <n>`。

## 5. 评测任务报 `no_rough_run_found`

- **现象**：`/data/proj1/runs` 下明明有目标 run。
- **根因**：补丁生成的 `<run>-config-backup` 目录同样匹配 glob，且字符串排序更靠后，被 `tail -1` 选中；该目录没有 `logs/`。
- **修复**：排除 `*-config-backup`，并要求候选目录必须真正包含 `logs/`。

## 6. 地形等级被写成 `-1`，触发负索引

- **现象**：评测 40 个环境全部落在同一块砖上，CSV 里 `terrain_level=-1`。
- **根因**：spread 分支残留 `levels[:] = level`，而 spread 模式下 `level` 是哨兵值 `-1`；Python 负索引把 `-1` 解释成最后一行。
- **修复**：删除该行，并对 `levels` 做 `clamp(0, max_level)`。

## 7. 手写出生点导致「刚出生就摔倒」

- **现象**：30 个 episode 长度 104~854，无一跑满。
- **根因**：直接把 `env_origins` 赋成 `terrain_origins[level, type]`，绕过了仓库的放置逻辑，机器人嵌进或悬空于台阶。
- **修复**：改用仓库自带 `simulator._get_env_origins()`，并记录 `spawn_base_height_min/mean/max` 作为诊断。

## 8. 通过率被误判为 0%

- **现象**：视频里明显在走，`pass_rate=0`。
- **根因**：判定条件写死 `length >= 999`，而环境真实上限不一定是 1000，且手动 reset 后 `episode_length_buf` 未清零。
- **修复**：从环境读取 `max_episode_length` 作为阈值，reset 后显式清零计数器。

## 9. 分档训练实际没有钉住档位

- **现象**：脚本打印 `level=0`，但日志 `Mean episode terrain_level: 0.4150`。
- **根因**：shell 只 `printf` 了档位，没有 `export PIN_TERRAIN_LEVEL`，Python 子进程读不到。
- **修复**：补 `export`，并增加两道断言：日志中必须出现 `pinned_terrain_level=<level>`；`Mean episode terrain_level` 偏离目标超过 0.1 时立即 `pin_drift` 退出。

## 10. 内置地形课程无法收敛（源码缺陷）

- **现象**：8000 迭代后平均地形等级只从 2.5 爬到 5.8，评测不稳定。
- **证据**（`legged_gym/envs/base/legged_robot.py`）：

  ```python
  move_up   = distance > env_length / 2                  # 4 m
  move_down = distance < |cmd| * 20s * 0.5               # 0.4*20*0.5 = 4 m
  ```

  两个阈值恰好相同，每个 episode 必然升一档或降一档，本质是随机游走。

- **补充证据**（`legged_gym/simulator/isaacgym_simulator.py`）：等级到顶后不是保持，而是 `randint` 随机跳到任意档，最难档永远无法巩固。
- **修复**：不再依赖该课程，改为「分档达标训练」；训练阶段把地形行钉死，达标才进入下一档（`scripts/staged_curriculum_job.sh`）。

## 11. 整包训练只跑了 100 次迭代

- **现象**：整合包默认 3000 迭代，实际日志是 `Learning iteration 99/100`。
- **根因**：包装脚本只 `export NUM_ENVS`，漏了 `MAX_ITERATIONS`，`train.sh` 用了自身默认值 100。
- **修复**：显式导出并打印 `effective_max_iterations`；`train.sh` 拒绝小于 500 的迭代数（需 `ALLOW_SMOKE_TEST=1` 才放行）。

## 12. 评测时机器人跑出地形列

- **现象**：视频里机器人走到外围平地，一直跑到边界才结束，`distance_x` 被刷高。
- **根因**：只锁了起点，没有横向约束；每列地形只有 8 m 宽。
- **修复**：加横向纠偏（`command_y = clamp(-1.2 * lateral, -0.3, 0.3)`），并在横向偏离 > 3.5 m 或 x 越界时立即终止，记录 `exit_reason=off_track / boundary`。
