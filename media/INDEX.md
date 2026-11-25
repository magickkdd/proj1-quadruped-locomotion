# 视频索引

视频托管在 Hugging Face：
**https://huggingface.co/A2bao/go2-quadruped-locomotion/tree/main/videos**

（直链把域名换成 `hf-mirror.com` 可在国内加速下载。）
本地 `media/` 目录保留同名副本。
下表是文件名与对应的测试条件。

## README 动图

| 文件 | 说明 |
|---|---|
| `early-failure.gif` | 早期评测失败：策略未正确加载时下沉、停止 |
| `flat-walk-validated.gif` | 修复评测链路后的平地行走验证 |
| `large-stair-failure.gif` | 早期较大台阶首次尝试，机器人无法通过 |
| `low-stair-first-attempt.gif` | 早期低台阶第一次尝试，机器人摔倒 |
| `low-stair-second-attempt.gif` | 早期低台阶第二次尝试，机器人勉强完成跨越 |
| `rough-slope.gif` | `model_8000.pt` 在平滑斜坡上的代表性片段 |
| `rough-random.gif` | `model_8000.pt` 在随机起伏地形上的代表性片段 |
| `rough-stairs.gif` | `model_8000.pt` 在楼梯地形上的代表性片段 |
| `rough-discrete.gif` | `model_8000.pt` 在离散障碍地形上的代表性片段 |
| `stairs-evaluation.gif` | 8000 迭代 checkpoint 的复杂地形行走片段，保留作总览 |

## 平地行走验证（checkpoint `model_3000.pt`，指令 0.3 m/s）

| 文件 | 说明 |
|---|---|
| `flat-walk-validated.mp4` | 行走验证通过：20/20 episode 满 1000 步，平均速度 0.266 m/s，最低机身高度 0.351 m |

## 粗糙地形 8000 迭代（task `go2_ts`，指令 0.4 m/s）

| 文件 | 说明 |
|---|---|
| `rough-8000-matrix.mp4` | 锁定档位矩阵评测的录制片段 |

## 连续地形行走（checkpoint `model_8000.pt`，从第 0 档沿 +X 连续行进）

| 文件 | 地形 | 距离 | 到达档位 | 结果 |
|---|---|---|---|---|
| `terrain_0_slope_a.mp4` | 平滑斜坡 A | 34.97 m | 4 | 摔倒 |
| `terrain_1_slope_b.mp4` | 平滑斜坡 B | 39.51 m | 4 | 摔倒 |
| `terrain_2_rough.mp4` | 随机起伏 | 19.09 m | 2 | 摔倒 |
| `terrain_3_stairs_a.mp4` | 楼梯 A | 12.13 m | 1 | 未摔但卡住 |
| `terrain_4_stairs_a.mp4` | 楼梯 A | 6.50 m | 0 | 未摔但卡住 |
| `terrain_5_stairs_a.mp4` | 楼梯 A | 30.91 m | 3 | 摔倒 |
| `terrain_6_stairs_b.mp4` | 楼梯 B | 7.01 m | 0 | 摔倒 |
| `terrain_7_stairs_b.mp4` | 楼梯 B | 9.75 m | 1 | 摔倒 |
| `terrain_8_discrete.mp4` | 离散障碍 | 18.82 m | 2 | 未摔但卡住 |
| `terrain_9_discrete.mp4` | 离散障碍 | 15.96 m | 1 | 摔倒 |

数据来源：`results/level-sweep/level_sweep_8000.csv`。

## 上传

```bash
HF_ENDPOINT=https://hf-mirror.com huggingface-cli upload \
  A2bao/go2-quadruped-locomotion ./media videos --repo-type model
```
