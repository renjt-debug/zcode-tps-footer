/**
 * ZCode 每答统计徽章注入脚本（DeepSeek 式胶囊：⚡ 186.9 tok/s | Σ 1.2k tok · 6.0s / 峰值 237.2）
 *
 * 挂载方式：由 app/ shim 在每次 did-finish-load 时 executeJavaScript 注入（幂等闸防重复）。
 * 数据源：http://127.0.0.1:3117/turns（常驻 tps_stats_server.py，口径=tps_footer.py=DeepSeek）。
 * 定位锚：ZCode 渲染层每轮对话是 <section data-turn-id="...">（虚拟滚动，滚到哪渲染哪）。
 * 取色：全部读 ZCode 主题 CSS 变量（--color-card/-border/-foreground/-trajectory-reasoning），
 *       自动跟随深浅色与 Skin Manager 皮肤；读不到时用深色兜底。
 * 设计约束：任何异常静默吞掉，绝不影响主界面；React 若删掉注入节点，observer 会重画。
 */
(() => {
  if (window.__tpsFooterLoaded) return;
  window.__tpsFooterLoaded = true;

  const API = "http://127.0.0.1:3117";
  const MARK = "data-tps-footer";
  const CLASS = "tps-footer-line";
  const CACHE_MS = 2000;

  let turns = [];
  let fetchedAt = 0;

  const norm = (s) => String(s || "").replace(/^turn_/, "");

  async function fetchTurns() {
    if (Date.now() - fetchedAt < CACHE_MS) return;
    try {
      const r = await fetch(`${API}/turns?limit=800&_=${Date.now()}`);
      const j = await r.json();
      if (Array.isArray(j.turns)) {
        turns = j.turns;
        fetchedAt = Date.now();
      }
    } catch {
      /* 服务未起，静默 */
    }
  }

  function fmtDur(ms) {
    const t = Math.max(0, Math.floor(ms / 1000));
    const m = Math.floor(t / 60);
    const s = t % 60;
    return m > 0 ? `${m}分${String(s).padStart(2, "0")}秒` : `${t}秒`;
  }
  function fmtLat(ms) {
    const s = Math.max(0, (ms || 0) / 1000);
    return s < 10 ? String(+s.toFixed(1)) : String(Math.round(s));
  }
  function fmtTps(v) {
    return v >= 10 ? String(Math.round(v)) : String(+Number(v).toFixed(1));
  }
  function fmtTok(n) {
    if (n >= 1000) {
      const k = n / 1000;
      return (k >= 100 ? Math.round(k) : +k.toFixed(1)) + "k";
    }
    return String(n);
  }
  function fmtStamp(ms) {
    const d = new Date(ms);
    const now = new Date();
    const hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
    if (d.toDateString() === now.toDateString()) return hm;
    const sameYear = d.getFullYear() === now.getFullYear();
    return sameYear
      ? `${d.getMonth() + 1}月${d.getDate()}日 ${hm}`
      : `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日 ${hm}`;
  }

  // 主题取色：读 ZCode 渲染层变量（:root / body 都探一遍），跟随深浅色与皮肤
  function themeColors() {
    const probes = [document.documentElement, document.body];
    const get = (name, fallback) => {
      for (const el of probes) {
        try {
          const v = getComputedStyle(el).getPropertyValue(name).trim();
          if (v) return v;
        } catch {}
      }
      return fallback;
    };
    const accent = get("--color-trajectory-reasoning", "#a78bfa");
    return {
      bg: get("--color-card", "rgba(30, 27, 46, 0.55)"),
      border: get("--color-border", "rgba(255, 255, 255, 0.10)"),
      fg: get("--color-foreground", "#e5e5e5"),
      sub: get("--color-foreground-subtle", "rgba(229, 229, 229, 0.60)"),
      accent,
      glow: accent.startsWith("#") ? accent + "26" : "rgba(0, 0, 0, 0.18)",
    };
  }

  function render(section, t) {
    if (section.querySelector(`[${MARK}]`)) return;
    if (!t.tps) {
      // 无测速样本：可能是失败/取消回合，也可能是成功回合但调用全缺 TTFT——
      // 后者仍有有效总输出，不能藏掉，标明"测速数据不足"
      const line = document.createElement("div");
      line.setAttribute(MARK, "1");
      line.className = CLASS;
      const parts = [fmtStamp(t.end_ms), `用时 ${fmtDur(t.run_ms)}`];
      if (t.ttft_ms != null && t.ttft_ms >= 0) parts.push(`首 token ${fmtLat(t.ttft_ms)}秒`);
      if (t.out_tokens) {
        parts.push(`总输出 ${fmtTok(t.out_tokens)} tok`, "测速数据不足");
        line.title = `总输出 ${t.out_tokens} tok（精确值）；本轮无有效测速样本`;
      }
      if (Array.isArray(t.models) && t.models.length) parts.push(t.models.join("/"));
      line.textContent = parts.join(" · ");
      Object.assign(line.style, {
        fontSize: "12px", opacity: "0.55", padding: "0 16px 4px",
        userSelect: "none", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
      });
      section.appendChild(line);
      return;
    }

    const c = themeColors();
    const row = document.createElement("div");
    row.setAttribute(MARK, "1");
    row.className = CLASS;
    row.style.cssText = "display:flex;justify-content:flex-end;padding:2px 12px 8px;";
    // 测速样本 token 数：与 decode_ms 同样本，Σ 显示值与速度可互相换算
    const mTok = t.measured_tokens != null ? t.measured_tokens : (t.out_tokens || 0);
    row.title = [
      fmtStamp(t.end_ms),
      `用时 ${fmtDur(t.run_ms)}`,
      t.ttft_ms != null && t.ttft_ms >= 0 ? `首 token ${fmtLat(t.ttft_ms)}秒` : "",
      t.tps ? `均速 ${t.tps} tok/s（${mTok} tok / ${t.decode_ms} ms）` : "",
      `总输出 ${t.out_tokens || 0} tok`,
      t.peak_tps ? `单步峰值 ${t.peak_tps} tok/s（单次调用最高均速）` : "",
      Array.isArray(t.models) && t.models.length ? t.models.join("/") : "",
    ].filter(Boolean).join(" · ");

    const pill = document.createElement("div");
    pill.style.cssText =
      "display:inline-flex;align-items:center;gap:9px;padding:6px 14px;border-radius:999px;" +
      "background:" + c.bg + ";border:1px solid " + c.border + ";" +
      "backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);" +
      "box-shadow:0 2px 14px " + c.glow + ";font-family:inherit;line-height:1;user-select:none;white-space:nowrap;";

    const bolt = document.createElement("span");
    bolt.textContent = "⚡";
    bolt.style.cssText = "font-size:11px;";
    const big = document.createElement("span");
    big.textContent = fmtTps(t.tps);
    big.style.cssText = "font-size:17px;font-weight:700;color:" + c.accent + ";font-variant-numeric:tabular-nums;";
    const unit = document.createElement("span");
    unit.textContent = "tok/s";
    unit.style.cssText = "font-size:10px;color:" + c.sub + ";margin-left:-7px;";
    pill.append(bolt, big, unit);

    const meta = document.createElement("div");
    meta.style.cssText =
      "display:flex;flex-direction:column;gap:3px;align-items:flex-end;" +
      "font-size:10px;color:" + c.sub + ";font-variant-numeric:tabular-nums;";
    const l1 = document.createElement("span");
    l1.textContent = `Σ ${fmtTok(mTok)} tok · ${t.decode_ms ? fmtLat(t.decode_ms) + "s" : fmtDur(t.run_ms)}`;
    const l2 = document.createElement("span");
    l2.textContent = "峰值 " + fmtTps(t.peak_tps || t.tps);
    meta.append(l1, l2);
    pill.appendChild(meta);

    row.appendChild(pill);
    section.appendChild(row);
    // 可见性自检：渲染了但量出 0 尺寸 → 上报，换挂载策略的依据
    requestAnimationFrame(() => {
      try {
        const r = pill.getBoundingClientRect();
        if (r.height === 0 || r.width === 0) ping(-2, `INVISIBLE host=${section.tagName} cls=${(section.className || "").slice(0, 60)}`);
      } catch {}
    });
  }

  let lastSecs = -1;
  function ping(secs, extra) {
    if (secs === lastSecs && !extra) return;
    lastSecs = secs;
    try {
      let snap = "";
      if (secs === 0) {
        snap =
          [...document.body.children]
            .map(
              (e) =>
                e.tagName +
                "[" +
                [...e.attributes].map((a) => a.name + "=" + (a.value || "").slice(0, 30)).join(",") +
                "]" +
                ">" +
                e.children.length
            )
            .join(" | ")
            .slice(0, 1400);
      } else if (extra) {
        snap = extra.slice(0, 1400);
      }
      fetch(`${API}/ping?secs=${secs}&snap=${encodeURIComponent(snap)}`).catch(() => {});
    } catch {}
  }

  let pending = false;
  async function scan() {
    if (pending) return;
    pending = true;
    try {
      const secs = document.querySelectorAll("section[data-turn-id]");
      if (!secs.length) {
        ping(0);
        return;
      }
      // 首扫上报真实 DOM 的 turn-id 原值（诊断匹配用）
      if (lastSecs < 0 || secs.length !== lastExpect) {
        lastExpect = secs.length;
        ping(
          secs.length,
          "IDS " +
            [...secs]
              .slice(0, 10)
              .map((s) => (s.getAttribute("data-turn-id") || "?").slice(0, 44))
              .join(",")
        );
      } else {
        ping(secs.length);
      }
      await fetchTurns();
      let matched = 0,
        rendered = 0,
        missed = 0;
      secs.forEach((s) => {
        if (s.querySelector(`[${MARK}]`)) {
          rendered++;
          return;
        }
        // 桥：界面 section[data-turn-id] 实为用户消息 ID（msg_xxx）→ turns[].msg_id
        const domId = norm(s.getAttribute("data-turn-id"));
        let t = turns.find((x) => norm(x.msg_id) === domId || norm(x.turn_id) === domId);
        if (!t && domId.length >= 16) {
          // 防御：DOM 属性若是截断版，退化为前缀匹配
          t = turns.find((x) => {
            const m = norm(x.msg_id);
            return m.startsWith(domId) || domId.startsWith(m);
          });
        }
        if (t) {
          matched++;
          render(s, t);
        } else {
          missed++;
        }
      });
      if (missed > 0 && matched === 0 && rendered === 0) {
        ping(-1, `NOMATCH dom=${secs.length} cache=${turns.length} first=${(secs[0].getAttribute("data-turn-id") || "?").slice(0, 44)} latest=${turns[0] ? turns[0].turn_id.slice(0, 44) : "?"}`);
      }
    } catch {
      /* 静默 */
    } finally {
      pending = false;
    }
  }
  let lastExpect = -2;

  function start() {
    try {
      const mo = new MutationObserver(() => {
        clearTimeout(mo._t);
        mo._t = setTimeout(scan, 300);
      });
      mo.observe(document.body, { childList: true, subtree: true });
      setInterval(scan, 4000);
      scan();
    } catch {
      /* 静默 */
    }
  }

  if (document.body) start();
  else document.addEventListener("DOMContentLoaded", start);
})();
