# 结果目录说明

| 目录 | 内容 | 结论 |
|---|---|---|
| `flat-clean/` | 平地从头训练 3000 迭代 + 评测 | 早期失败基线：评测未加载 checkpoint，视频里机器人下沉不动 |
| `flat-walk/` | 修复权重加载后的平地评测 | **通过**：20/20 episode 满 1000 步，平均速度 0.266 m/s，`behavior_gate=pass` |
| `rough-8000/` | `go2_ts` 粗糙地形 8000 迭代训练 + 矩阵评测 | 训练指标正常（episode 987、tracking 0.90），评测端通过率统计有缺陷，见 `docs/05-debug-log.md` |
| `rough-staged/` | 分档达标训练的日志尾部 | 10 档全部 `mastered=1`，但评测未通过，说明分档训练把分布压窄导致泛化下降 |
| `level-sweep/` | `model_8000.pt` 的 10 类地形连续行走结果 | 当前能力上限：斜坡 35~40 m，楼梯 6~31 m，多数摔倒 |

约定：

- 文件名保留云端 run_id，便于和 `/data/proj1/runs/` 对照
- `*.log` 是完整主日志，`*.summary.txt` 是聚合指标，`*.csv` 是逐 episode 或逐地形明细
- 两个完整训练日志体积过大（4~12 MB），仓库中每条仅保留末尾 300 行，完整日志在云端 `/data/proj1/results/`
- 所有指标均为仿真结果
