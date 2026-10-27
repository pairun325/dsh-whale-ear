#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dsh-whale-ear: 听系统声音 / 麦克风，转成文字。

用法：
    python listen.py --source loopback|mic|both --model base --lang zh

输出：每识别出一段，往 stdout 打一行 JSON，同时追加到 --out 文件。
状态：写到 --state 文件，插件读它判断在线不在线。
停止：看到 --stop 文件就退出。
"""
import argparse
import json
import os
import queue
import signal
import sys
import threading
import time

import numpy as np

# HuggingFace 直连经常被卡，默认走镜像；xet 后端在国内会 401，关掉。
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")

SAMPLE_RATE = 16000
CHUNK_MS = 100
CHUNK = int(SAMPLE_RATE * CHUNK_MS / 1000)

SILENCE_START = 0.012      # 开始收音的能量门槛
SILENCE_END_MS = 700       # 静音多久算一句说完
MIN_UTTER_MS = 500         # 太短的不送识别
MAX_UTTER_MS = 12000       # 太长强制切


def log(msg):
    sys.stderr.write("[ear] %s\n" % msg)
    sys.stderr.flush()


def write_state(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def open_stream(source):
    """返回 (mic, samplerate, label)。"""
    import soundcard as sc
    if source == "loopback":
        speaker = sc.default_speaker()
        mic = sc.get_microphone(id=str(speaker.name), include_loopback=True)
        return mic, speaker.name, "loopback"
    mic = sc.default_microphone()
    return mic, mic.name, "mic"


def resample(x, src_rate, dst_rate):
    if src_rate == dst_rate or x.size == 0:
        return x
    n = int(round(x.size * dst_rate / src_rate))
    if n <= 0:
        return np.zeros(0, dtype=np.float32)
    idx = np.linspace(0, x.size - 1, n)
    return np.interp(idx, np.arange(x.size), x).astype(np.float32)


def make_reader(mic, q, stop_flag):
    """一个线程不停录，统一重采样到 16k 后塞进队列。

    有些声卡（尤其耳机）在共享模式下不给 16k，所以从高往低试。
    """
    def run():
        last_exc = None
        for rate in (16000, 48000, 44100, 32000):
            try:
                block = max(256, int(rate * CHUNK_MS / 1000))
                with mic.recorder(samplerate=rate, channels=1, blocksize=block) as rec:
                    log("采样率 %d Hz 打开成功" % rate)
                    while not stop_flag.is_set():
                        data = rec.record(numframes=block)
                        if data is None:
                            continue
                        mono = np.asarray(data, dtype=np.float32)
                        if mono.ndim > 1:
                            mono = mono[:, 0]
                        q.put(resample(mono, rate, SAMPLE_RATE))
                    return
            except Exception as exc:  # noqa: BLE001
                last_exc = exc
                continue
        log("采样打不开：%s" % last_exc)
        q.put(None)

    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default="loopback", choices=["loopback", "mic", "both"])
    ap.add_argument("--model", default="base")
    ap.add_argument("--lang", default="zh")
    ap.add_argument("--out", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--stop", required=True)
    ap.add_argument("--silence-ms", type=int, default=5000, help="静音多久算一句说完")
    ap.add_argument("--max-sec", type=float, default=20.0, help="单句最长秒数，超了强切")
    args = ap.parse_args()

    global SILENCE_END_MS, MAX_UTTER_MS
    SILENCE_END_MS = max(50, min(15000, args.silence_ms))
    MAX_UTTER_MS = int(max(1.0, min(30.0, args.max_sec)) * 1000)

    from faster_whisper import WhisperModel
    log("加载模型 %s（第一次会自动下载）" % args.model)
    model = WhisperModel(args.model, device="cpu", compute_type="int8")
    log("模型就绪")

    stop_flag = threading.Event()

    def on_term(*_):
        stop_flag.set()
    signal.signal(signal.SIGINT, on_term)
    signal.signal(signal.SIGTERM, on_term)

    sources = []
    if args.source == "both":
        for s in ("loopback", "mic"):
            mic, name, label = open_stream(s)
            sources.append((label, name, mic))
    else:
        mic, name, label = open_stream(args.source)
        sources.append((label, name, mic))

    qs = []
    for label, name, mic in sources:
        q = queue.Queue()
        make_reader(mic, q, stop_flag)
        qs.append({"label": label, "name": name, "q": q, "buf": [], "recording": False,
                   "silence": 0, "last": 0})
        log("开始听 %s（%s）" % (label, name))

    out = open(args.out, "a", encoding="utf-8")
    deliver_path = os.path.join(os.path.dirname(os.path.abspath(args.out)), "deliver.jsonl")
    lines = 0
    state = {"running": True, "source": args.source, "model": args.model,
             "lines": 0, "last": "", "started": time.time(),
             "streams": [{"label": l, "name": n} for l, n, _ in sources]}

    # whisper 对同音昵称不敏感，这里把常见误听掰回原词。
    FIXES = (
        ("大飞鱼", "大肥鱼"), ("打肥鱼", "大肥鱼"), ("大肥于", "大肥鱼"),
        ("打飞鱼", "大肥鱼"), ("大非鱼", "大肥鱼"), ("大肥鱼", "大肥鱼"),
        ("经经", "鲸鲸"), ("晶晶", "鲸鲸"), ("精精", "鲸鲸"),
        ("鲸鱼娘", "鲸鱼娘"), ("惊鱼娘", "鲸鱼娘"), ("鲸鱼良", "鲸鱼娘"),
        ("肥鱼", "肥鱼"),
    )

    def fix_text(text):
        for bad, good in FIXES:
            if bad != good:
                text = text.replace(bad, good)
        return text

    def emit(label, text):
        nonlocal lines
        text = fix_text(text.strip())
        if not text:
            return
        lines += 1
        rec = {"t": time.time(), "src": label, "text": text}
        out.write(json.dumps(rec, ensure_ascii=False) + "\n")
        out.flush()
        sys.stdout.write(json.dumps(rec, ensure_ascii=True) + "\n")
        sys.stdout.flush()
        state["lines"] = lines
        state["last"] = text
        state["last_t"] = rec["t"]
        write_state(args.state, state)
        # 麦克风这条线（主人自己说的话）才转给 DSH 当消息；系统音那路只记录不打断。
        if label == "mic" and len(text) >= 2:
            try:
                with open(deliver_path, "a", encoding="utf-8") as dh:
                    dh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            except OSError as exc:
                log("写 deliver.jsonl 失败: %s" % exc)

    def transcribe(buf, label):
        audio = np.concatenate(buf).astype(np.float32)
        peak = float(np.max(np.abs(audio))) if audio.size else 0.0
        if peak > 1.0:
            audio = audio / peak
        # 麦克风默认按中文处理（热词 + 简体引导）；环回可能放外语，走自动识别。
        auto_mode = args.lang in ("", "auto")
        use_auto = auto_mode and label != "mic"
        want_zh = (not use_auto) and (auto_mode or args.lang.startswith("zh"))
        prompt = (
            "以下是普通话口语对话，说话人常提到鲸鲸、大肥鱼、鲸鱼娘这几个名字。用简体中文转写。"
            if want_zh
            else None
        )
        segs, info = model.transcribe(
            audio,
            language=None if use_auto else ("zh" if want_zh else args.lang),
            vad_filter=True,
            condition_on_previous_text=False,
            beam_size=1,
            no_speech_threshold=0.6,
            initial_prompt=prompt,
        )
        text = "".join(s.text for s in segs)
        if text.strip():
            lang_used = getattr(info, "language", None) or getattr(info, "language_code", None)
            if lang_used and use_auto:
                text = "[%s] %s" % (lang_used, text)
        emit(label, text)

    write_state(args.state, state)

    try:
        while not stop_flag.is_set():
            if os.path.exists(args.stop):
                log("收到停止信号")
                break
            busy = False
            for st in qs:
                try:
                    chunk = st["q"].get(timeout=0.05)
                except queue.Empty:
                    continue
                if chunk is None:
                    log("%s 采样线程退出了" % st["label"])
                    st["q"] = queue.Queue()
                    q = st["q"]
                    make_reader([m for l, n, m in sources if l == st["label"]][0], q, stop_flag)
                    continue
                busy = True
                rms = float(np.sqrt(np.mean(np.square(chunk)))) if chunk.size else 0.0
                if rms > SILENCE_START:
                    st["recording"] = True
                    st["silence"] = 0
                    st["buf"].append(chunk)
                elif st["recording"]:
                    st["buf"].append(chunk)
                    st["silence"] += CHUNK_MS
                    if st["silence"] >= SILENCE_END_MS:
                        audio_len = sum(len(c) for c in st["buf"]) * 1000 / SAMPLE_RATE
                        if audio_len >= MIN_UTTER_MS:
                            try:
                                transcribe(st["buf"], st["label"])
                            except Exception as exc:  # noqa: BLE001
                                log("识别失败：%s" % exc)
                        st["buf"] = []
                        st["recording"] = False
                        st["silence"] = 0
                else:
                    # 静音时保留一点点上下文，避免吃掉句首
                    st["buf"] = st["buf"][-4:] + [chunk]
                total = sum(len(c) for c in st["buf"]) * 1000 / SAMPLE_RATE
                if total >= MAX_UTTER_MS:
                    try:
                        transcribe(st["buf"], st["label"])
                    except Exception as exc:  # noqa: BLE001
                        log("识别失败：%s" % exc)
                    st["buf"] = []
                    st["recording"] = False
                    st["silence"] = 0
            if not busy:
                time.sleep(0.01)
    finally:
        state["running"] = False
        write_state(args.state, state)
        out.close()
        log("退出，共 %d 句" % lines)


if __name__ == "__main__":
    main()
