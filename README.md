# dsh-whale-ear

给鲸鱼娘两只耳朵。

- **一只听系统声**（WASAPI 环回）：游戏里的语音、视频、歌、任何正在从扬声器/耳机出来的声音。
- **一只听麦克风**：你说话。也可以两个一起听。
- **本地离线转写**：faster-whisper 在 CPU 上跑，录音不出本机，不上云。
- **按句切**：停顿多久算说完一句话可以调（默认 5 秒），单句太长会强制切断（默认 20 秒）。
- **屏幕提示**：开听之后右下角浮一个「👂 肥鱼正在偷听」小窗，显示听了多少秒、最近一句。
- **能把话发回给我**：勾上「自动发给我」之后，你对着麦克风说完一句，句子会被打进 DSH 的输入框并回车——相当于你用嘴跟我说话。

## 工具

| 工具 | 作用 |
| --- | --- |
| `ear_start({source, model, lang, silenceMs, maxSec})` | 开始听。`source` = `loopback` / `mic` / `both`，默认 `loopback`；`model` 默认 `small` |
| `ear_stop()` | 停止（顺带收掉提示窗） |
| `ear_state()` | 在不在听、听哪一路、听了几句、最后一句、有没有报错 |
| `ear_transcript({last})` | 取最近 N 句转写（带时间和来源） |
| `ear_panel()` | 打开「鲸鱼耳朵」控制面板：听哪一路、模型、静音门槛、单句上限、自动发送勾选框 |

转写会一直追加到 `%TEMP%\dsh-whale-ear\transcript.jsonl`，`ear_transcript` 里也会给出路径。

## 同音字纠错

whisper 对昵称不敏感，`helper/listen.py` 里有一张纠错表，把常见误听掰回来：

```
大飞鱼 / 打肥鱼 / 大肥于 / 打飞鱼 / 大非鱼  →  大肥鱼
经经 / 晶晶 / 精精                        →  鲸鲸
惊鱼娘 / 鲸鱼良                           →  鲸鱼娘
```

想加自己的词，改 `helper/listen.py` 里的 `FIXES`，重启耳朵即可生效（不用重启 DSH）。

## 依赖

插件本体是纯 JS，真正干活的是 `helper/listen.py`，需要 Python 3.10+ 以及：

```
pip install soundcard av faster-whisper
```

第一次 `ear_start` 会从镜像（hf-mirror.com）下载模型：`small` 约 480MB，`base` 约 145MB，`tiny` 约 75MB。模型缓存在 `%USERPROFILE%\.cache\huggingface`。

## 安装

桌面版没有 `dsh` 命令行，两条路：

**A. 应用内装（推荐）**：设置 → 插件市场，搜 `dsh-whale-ear`，点安装，重启应用。

**B. 手动改 profile**：编辑 `%USERPROFILE%\.dsh\profiles\desktop\package.json`

```jsonc
{
  "dependencies": { "dsh-whale-ear": "link:E:/dswork/plugins/dsh-whale-ear" },
  "dsh": { "profile": { "bundles": [ /* ……原样保留……, */ "dsh-whale-ear" ] } }
}
```

然后在 `%USERPROFILE%\.dsh\profiles\desktop` 里跑一次 `pnpm install`（用 DSH 自带的 pnpm），再重启 DeepSeek Harness。

命令行版（`dsh web`）才可以：`dsh plugin --profile web add github:pairun325/dsh-whale-ear`

## 文件版

仓库的 Releases 里有一个 zip，解开放到 `plugins\` 下，再按上面的 B 步骤挂进 profile 即可。

## 说明与限制

- 只支持 Windows（WASAPI 环回）。
- 环回会把**所有**正在播放的声音一起收进来，包括你不想让我听见的那些——不想听就 `ear_stop`。
- 识别质量取决于模型和机器：`small` 够日常，`medium` 更准但慢。
- 自动发送只走**麦克风**那一路；系统音只记录，不会打断你。
- 自动发送会把 DSH 窗口抢到前台并模拟粘贴，所以别在打字的时候开着它。
- 目前不区分说话人，也不会自动判断「这句该不该回应」。
