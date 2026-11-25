# 提交包索引

每个包都是自包含的训练/评测任务：上传到训练平台后自动解压到 `/code/workspace`，用一条命令启动。
包体本身不纳入 Git，构建源码见 `scripts/`。

| 包 | 用途 | 启动命令 | SHA256 |
|---|---|---|---|
| `go2_wtw_rough_v1.tar.gz` | Walk These Ways 配置，4096 环境 / 4000 迭代，训练后自动连续地形评测 | `bash /code/workspace/scripts/train_wtw_job.sh` | `d28704a78e4c5a758ca2b8a7826a1b3ed4e967a79c7c161e5812d24d8ca29398` |
| `go2_level_sweep_eval_v3.tar.gz` | 只用已有 checkpoint 做连续地形评测，支持 `TERRAIN_LEVEL` 指定起始档位 | `bash /code/workspace/scripts/eval_level_sweep_entry.sh` | `121be43755a587b4a89e52afec735725ecc22e07515be5e0a74abf12d2629ea7` |
| `go2_level_ab_v1.tar.gz` | 同一 checkpoint 在第 9 档与第 0 档各跑一次，用于判定档位方向 | `bash /code/workspace/scripts/eval_level_compare_job.sh` | `21c71ca1a71a211fc3249f0fe6091a709011ad292eb6d628ad3992de812d9f53` |
| `go2_staged_mastery_v2.tar.gz` | 分档达标训练（0→9，达标才升级），训练后自动评测 | `bash /code/workspace/scripts/staged_curriculum_job.sh` | `d150e224016c3d94514215705cfcca690872179493be4fcab086f523095677a3` |
| `go2_flat_clean_train_eval_v3.tar.gz` | 平地从头训练 + 评测 + 录制，一体化 | `bash /code/workspace/scripts/train_eval_record_job.sh` | `355db511ddc3eb65d97954bede2d28aeb4c4bdeca36a464c01da007ee2701327` |
| `go2_eval_repair_v1.tar.gz` | 修复评测权重加载协议，复用已有 checkpoint | `bash /code/workspace/scripts/eval_repair_job.sh` | `40b7c3c769878fd1f56a7b66dda04e8e7c32ac6a736f93d6d268f54d436564ed` |

## 通用环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DATA_ROOT` | `/data/proj1` | 持久化目录（环境包、仓库、结果） |
| `NUM_ENVS` | 4096 | 并行环境数 |
| `MAX_ITERATIONS` | 按包 | 训练迭代数 |
| `COMMAND_X` | 0.4 | 评测指令速度 m/s |
| `TYPES` | `0..9` | 评测的地形列 |
| `TERRAIN_LEVEL` | 0 | 评测起始档位 |
| `CHECKPOINT_PATH` | 自动选择 | 指定 checkpoint |
