/**
 * dsh-whale-ear —— 给鲸鱼娘两只耳朵。
 *
 * 一只听系统正在放的声音（WASAPI 环回：游戏、视频、歌），
 * 一只听麦克风（你说话）。
 * 本地离线转写（faster-whisper），不联网，录音不上传。
 *
 * 工具：
 *   ear_start    开始听（source: loopback | mic | both）
 *   ear_stop     停
 *   ear_state    在线状态、听了多少句、最近一句
 *   ear_transcript  取最近的转写
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const name = 'dsh-whale-ear';
export const inject = ['tools'];

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_HELPER = path.join(HERE, '..', 'helper', 'listen.py');
const BADGE_PS1 = path.join(HERE, '..', 'helper', 'badge.ps1');
const PANEL_PS1 = path.join(HERE, '..', 'helper', 'panel.ps1');
const DELIVER_PS1 = path.join(HERE, '..', 'helper', 'deliver.ps1');
const WORK_DIR = path.join(os.tmpdir(), 'dsh-whale-ear');

function resolvePython(configured) {
  if (typeof configured === 'string' && configured.trim() !== '') return configured.trim();
  const env = process.env.DSH_WHALE_EAR_PYTHON;
  if (typeof env === 'string' && env.trim() !== '') return env.trim();
  const bundled = path.join(
    path.dirname(process.execPath),
    'resources',
    'runtime',
    'primary-runtime',
    'dependencies',
    'python',
    'python.exe',
  );
  if (fs.existsSync(bundled)) return bundled;
  const fallback = 'E:/ds/resources/runtime/primary-runtime/dependencies/python/python.exe';
  if (fs.existsSync(fallback)) return fallback;
  return 'python';
}

export function apply(ctx, config = {}) {
  const LOAD_MARK = path.join(os.tmpdir(), 'dsh-whale-ear-load.json');
  const mark = (stage, extra = {}) => {
    try {
      fs.writeFileSync(LOAD_MARK, JSON.stringify({ at: new Date().toISOString(), stage, pid: process.pid, ...extra }, null, 2));
    } catch {}
  };
  mark('apply-enter');

  const python = resolvePython(config.python);
  const helper = typeof config.helperScript === 'string' && config.helperScript !== ''
    ? config.helperScript
    : DEFAULT_HELPER;
  const defaultModel = typeof config.model === 'string' && config.model !== '' ? config.model : 'small';
  const defaultLang = typeof config.lang === 'string' && config.lang !== '' ? config.lang : 'zh';
  const maxLines = Number.isFinite(Number(config.maxLines)) ? Math.max(20, Number(config.maxLines)) : 500;

  fs.mkdirSync(WORK_DIR, { recursive: true });
  const stateFile = path.join(WORK_DIR, 'state.json');
  const transcriptFile = path.join(WORK_DIR, 'transcript.jsonl');
  const stopFile = path.join(WORK_DIR, 'stop');
  const cmdFile = path.join(WORK_DIR, 'cmd.json');
  const cfgFile = path.join(WORK_DIR, 'settings.json');

  /** @type {{proc: import('node:child_process').ChildProcess|null, lines: Array<{t:number,src:string,text:string}>, stderr: string[], startedAt: number, source: string, model: string}} */
  const session = { proc: null, deliver: null, panel: null, badge: null, lines: [], stderr: [], startedAt: 0, source: '', model: '' };
  const disposers = [];

  function readState() {
    try {
      return JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    } catch {
      return null;
    }
  }

  function alive() {
    return session.proc !== null && session.proc.exitCode === null && !session.proc.killed;
  }

  function pushLine(rec) {
    session.lines.push(rec);
    if (session.lines.length > maxLines) session.lines.splice(0, session.lines.length - maxLines);
  }

  function start({ source = 'loopback', model = defaultModel, lang = defaultLang, silenceMs = 5000, maxSec = 20 } = {}) {
    if (alive()) {
      return { ok: false, reason: '已经在听了，先 ear_stop', source: session.source };
    }
    try {
      fs.rmSync(stopFile, { force: true });
    } catch {
      /* ignore */
    }
    session.lines = [];
    session.stderr = [];
    session.startedAt = Date.now();
    session.source = source;
    session.model = model;
    const args = [
      helper,
      '--source', source,
      '--model', model,
      '--lang', lang,
      '--silence-ms', String(silenceMs),
      '--max-sec', String(maxSec),
      '--out', transcriptFile,
      '--state', stateFile,
      '--stop', stopFile,
    ];
    const proc = spawn(python, args, {
      cwd: path.dirname(helper),
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHONUTF8: '1' },
    });
    session.proc = proc;
    let buf = '';
    proc.stdout.setEncoding('utf8');
    proc.stdout.on('data', (chunk) => {
      buf += chunk;
      let idx;
      while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx).trim();
        buf = buf.slice(idx + 1);
        if (line === '') continue;
        try {
          const rec = JSON.parse(line);
          if (rec && typeof rec.text === 'string') pushLine(rec);
        } catch {
          /* 非 JSON 行忽略 */
        }
      }
    });
    proc.stderr.setEncoding('utf8');
    proc.stderr.on('data', (chunk) => {
      session.stderr.push(String(chunk).trim());
      if (session.stderr.length > 20) session.stderr.shift();
    });
    proc.on('exit', () => {
      session.proc = null;
    });
    startBadge();
    startDeliver();
    return { ok: true, source, model, lang, pid: proc.pid };
  }

  /** 屏幕角落那块「肥鱼正在偷听」的小窗，跟着耳朵一起开关。 */
  function startBadge() {
    if (!fs.existsSync(BADGE_PS1)) return;
    if (session.badge && session.badge.exitCode === null) return;
    try {
      const child = spawn(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', BADGE_PS1, '-StateFile', stateFile],
        { windowsHide: true, stdio: 'ignore' },
      );
      child.on('exit', () => {
        if (session.badge === child) session.badge = null;
      });
      session.badge = child;
    } catch {
      /* 提示窗起不来不影响听 */
    }
  }

  function stopBadge() {
    const child = session.badge;
    session.badge = null;
    if (!child) return;
    try {
      if (child.exitCode === null) child.kill();
    } catch {
      /* ignore */
    }
  }

  // ---- 控制面板（helper/panel.ps1）----
  // 面板不直接调插件，它把要做的动作写进 cmd.json；插件这边轮询执行，所以面板随时改设置都生效。
  const settings = { source: 'both', model: defaultModel, lang: 'auto', silenceMs: 5000, maxSec: 20, autoDeliver: false };

  function saveSettings() {
    try {
      fs.writeFileSync(cfgFile, JSON.stringify(settings, null, 2), 'utf8');
    } catch {
      /* ignore */
    }
  }

  function loadSettings() {
    try {
      const raw = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
      for (const k of Object.keys(settings)) {
        if (raw && raw[k] !== undefined && raw[k] !== null) settings[k] = raw[k];
      }
    } catch {
      /* 第一次没有文件很正常 */
    }
    saveSettings();
  }

  let lastCmdSeq = 0;

  function handleCmd(cmd) {
    if (!cmd || typeof cmd !== 'object') return;
    const seq = Number(cmd.seq);
    if (!Number.isFinite(seq) || seq <= lastCmdSeq) return;
    lastCmdSeq = seq;
    if (typeof cmd.silenceMs === 'number' && cmd.silenceMs > 0) settings.silenceMs = cmd.silenceMs;
    if (typeof cmd.maxSec === 'number' && cmd.maxSec > 0) settings.maxSec = cmd.maxSec;
    if (typeof cmd.source === 'string' && cmd.source !== '') settings.source = cmd.source;
    if (typeof cmd.model === 'string' && cmd.model !== '') settings.model = cmd.model;
    if (typeof cmd.autoDeliver === 'boolean') settings.autoDeliver = cmd.autoDeliver;
    saveSettings();
    if (cmd.cmd === 'kick-deliver') {
      stopDeliver();
      startDeliver();
      return;
    }
    if (cmd.cmd === 'start') {
      if (alive()) stop();
      setTimeout(() => start({ ...settings }), alive() ? 2600 : 0);
    } else if (cmd.cmd === 'stop') {
      if (alive()) stop();
    }
  }

  function pollCmd() {
    try {
      const raw = fs.readFileSync(cmdFile, 'utf8');
      const cmd = JSON.parse(raw);
      if (cmd && Number(cmd.seq) > lastCmdSeq) handleCmd(cmd);
    } catch {
      /* 没命令 */
    }
  }

  function startPanel() {    if (!fs.existsSync(PANEL_PS1)) return { ok: false, reason: 'panel.ps1 不见了' };
    if (session.panel && session.panel.exitCode === null) return { ok: true, already: true };
    try {
      const child = spawn(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          PANEL_PS1,
          '-WorkDir',
          WORK_DIR,
        ],
        { windowsHide: true, stdio: 'ignore' },
      );
      child.on('exit', () => {
        if (session.panel === child) session.panel = null;
      });
      session.panel = child;
      return { ok: true };
    } catch (err) {
      return { ok: false, reason: String(err && err.message ? err.message : err) };
    }
  }

  // ---- 投递器（helper/deliver.ps1）：把麦克风听完整的句子自动打进 DSH 输入框 ----
  function startDeliver() {
    if (!fs.existsSync(DELIVER_PS1)) return;
    if (session.deliver && session.deliver.exitCode === null) return;
    try {
      const child = spawn(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', DELIVER_PS1, '-WorkDir', WORK_DIR],
        { windowsHide: true, stdio: 'ignore' },
      );
      child.on('exit', () => {
        if (session.deliver === child) session.deliver = null;
      });
      session.deliver = child;
    } catch {
      /* 投递器起不来不影响听 */
    }
  }

  function stopDeliver() {
    const child = session.deliver;
    session.deliver = null;
    if (!child) return;
    try {
      if (child.exitCode === null) child.kill();
    } catch {
      /* ignore */
    }
  }

  function stop() {
    if (!alive()) return { ok: true, stopped: false, reason: '本来就没在听' };
    try {
      fs.writeFileSync(stopFile, String(Date.now()), 'utf8');
    } catch {
      /* ignore */
    }
    const pid = session.proc.pid;
    setTimeout(() => {
      try {
        if (session.proc && session.proc.exitCode === null) session.proc.kill();
      } catch {
        /* ignore */
      }
    }, 2500);
    stopBadge();
    stopDeliver();
    return { ok: true, stopped: true, pid };
  }

  const OUT = {
    schema: { type: 'object', additionalProperties: true, required: ['ok'], properties: { ok: { type: 'boolean' } } },
    render: (_args, value) => [
      {
        type: 'text',
        text: typeof value === 'string' ? value : JSON.stringify(value, null, 2),
      },
    ],
  };

  const safeRegister = (spec) => {
    try {
      disposers.push(ctx.tools.register(spec));
      mark('registered:' + spec.name);
    } catch (err) {
      mark('register-failed:' + spec.name, { message: String((err && err.stack) || err) });
      throw err;
    }
  };

  safeRegister({
      name: 'ear_start',
      description:
        '让鲸鱼娘开始听。source=loopback 听系统正在放的声音（游戏/视频/音乐），mic 听麦克风，both 两个都听。本地离线转写，不联网；第一次用会下载模型（base 约 145MB）。',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          source: { type: 'string', enum: ['loopback', 'mic', 'both'], description: '听哪一路，默认 loopback' },
          model: { type: 'string', description: 'whisper 模型：tiny/base/small/medium，默认 small' },
          lang: { type: 'string', description: '语言代码，默认 zh；auto = 自动识别（麦克风仍按中文）' },
          silenceMs: { type: 'number', description: '静音多久算一句说完，默认 5000ms（停顿 5 秒算一句），越小切句越快但容易切断' },
          maxSec: { type: 'number', description: '单句最长秒数，默认 20，超了强制切' },
        },
      },
      output: OUT,
      async execute(args = {}) {
        const source = typeof args.source === 'string' ? args.source : 'loopback';
        const result = start({
          source,
          model: args.model,
          lang: args.lang,
          silenceMs: typeof args.silenceMs === 'number' ? args.silenceMs : 5000,
          maxSec: typeof args.maxSec === 'number' ? args.maxSec : 20,
        });
        return result;
      },
    });

  safeRegister({
      name: 'ear_stop',
      description: '让鲸鱼娘不要听了。',
      parameters: { type: 'object', additionalProperties: false, properties: {} },
      output: OUT,
      async execute() {
        return stop();
      },
    });

  safeRegister({
      name: 'ear_state',
      description: '看看耳朵在不在听：进程活着没、听哪一路、已经听了几句、最近一句是什么、有没有报错。',
      parameters: { type: 'object', additionalProperties: false, properties: {} },
      output: OUT,
      async execute() {
        const state = readState();
        return {
          ok: true,
          listening: alive(),
          source: session.source || (state && state.source) || '',
          model: session.model || (state && state.model) || defaultModel,
          lines: state && Number.isFinite(state.lines) ? state.lines : session.lines.length,
          last: (state && state.last) || (session.lines.at(-1)?.text ?? ''),
          uptimeSec: session.startedAt ? Math.round((Date.now() - session.startedAt) / 1000) : 0,
          stderr: session.stderr.slice(-5),
        };
      },
    });

  safeRegister({
      name: 'ear_transcript',
      description: '取最近听到的文字（转写结果），默认最近 20 句，带时间戳和来源（loopback/mic）。',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          last: { type: 'number', description: '要几句，默认 20' },
          withFile: { type: 'boolean', description: '要不要把整份记录的文件路径也带上，默认 true' },
        },
      },
      output: OUT,
      async execute(args = {}) {
        const n = Number.isFinite(Number(args.last)) ? Math.max(1, Math.min(maxLines, Number(args.last))) : 20;
        let all = session.lines;
        if (all.length === 0) {
          try {
            const text = fs.readFileSync(transcriptFile, 'utf8');
            all = text
              .split('\n')
              .filter((l) => l.trim() !== '')
              .slice(-maxLines)
              .map((l) => {
                try {
                  return JSON.parse(l);
                } catch {
                  return null;
                }
              })
              .filter(Boolean);
          } catch {
            all = [];
          }
        }
        const tail = all.slice(-n);
        return {
          ok: true,
          count: tail.length,
          lines: tail.map((r) => ({ time: new Date(r.t * 1000).toLocaleTimeString(), src: r.src, text: r.text })),
          file: args.withFile === false ? undefined : transcriptFile,
        };
      },
    });

  safeRegister({
      name: 'ear_panel',
      description: '打开耳朵的控制面板：开始/停止、静音门槛、单句上限、听哪一路、换模型，都在那个小窗里点。',
      parameters: { type: 'object', additionalProperties: false, properties: {} },
      output: OUT,
      async execute() {
        return startPanel();
      },
    });

  mark('tools-registered', { tools: 5, python, helper });

  loadSettings();
  // 启动时状态文件可能是上次没关干净的，先标成「没在听」，免得面板显示假的「在听」。
  if (!alive()) {
    try {
      fs.writeFileSync(stateFile, JSON.stringify({ running: false, source: '', model: '', lines: 0, last: '', last_t: 0 }), 'utf8');
    } catch {
      /* ignore */
    }
  }
  const cmdTimer = setInterval(pollCmd, 400);
  cmdTimer.unref?.();

  return {
    dispose() {
      clearInterval(cmdTimer);
      stop();
      stopBadge();
      stopDeliver();
      for (const d of disposers) {
        try {
          d();
        } catch {
          /* ignore */
        }
      }
    },
  };
}
