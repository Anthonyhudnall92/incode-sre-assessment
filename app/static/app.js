// Uptime board. Renders /api/monitors as text only (never innerHTML), polls
// every 10 seconds, and keeps the delete tokens for sites added from this
// browser in localStorage.

(() => {
  "use strict";

  const POLL_MS = 10000;
  const STRIP = 40;
  const TOKENS_KEY = "uptime-board-tokens";
  const INTERVAL_LABEL = { 60: "every minute", 300: "every 5 min", 900: "every 15 min", 3600: "every hour" };

  const $ = (id) => document.getElementById(id);
  const board = $("board");
  const form = $("add-form");
  const message = $("form-message");

  // --- Tokens (only this browser can remove what it added) ---------------------
  function loadTokens() {
    try { return JSON.parse(localStorage.getItem(TOKENS_KEY)) || {}; } catch { return {}; }
  }
  function saveTokens(tokens) {
    try { localStorage.setItem(TOKENS_KEY, JSON.stringify(tokens)); } catch { /* private mode */ }
  }
  let tokens = loadTokens();

  // --- Helpers ---------------------------------------------------------------
  function el(tag, props = {}, children = []) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props)) {
      if (key === "text") node.textContent = value;
      else if (key === "class") node.className = value;
      else if (key === "dataset") Object.assign(node.dataset, value);
      else node.setAttribute(key, value);
    }
    for (const child of children) if (child) node.append(child);
    return node;
  }

  function ago(iso) {
    const seconds = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
    if (seconds < 60) return `${seconds}s ago`;
    if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
    return `${Math.round(seconds / 3600)} h ago`;
  }

  function clock(iso) {
    return new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  function stateOf(m) {
    if (!m.last) return "pending";
    return m.last.ok ? "up" : "down";
  }

  // --- Rendering ---------------------------------------------------------------
  function strip(m) {
    const node = el("div", { class: "strip", role: "img" });
    const checks = m.recent || [];
    const slowest = Math.max(300, ...checks.filter((c) => c.ok).map((c) => c.ms));
    const failed = checks.filter((c) => !c.ok).length;
    node.setAttribute(
      "aria-label",
      checks.length ? `${checks.length} recent checks, ${failed} failed` : "No checks yet",
    );
    for (let i = 0; i < STRIP - checks.length; i++) node.append(el("span", { class: "bar is-empty" }));
    for (const c of checks) {
      const bar = el("span", { class: c.ok ? "bar" : "bar is-down" });
      if (c.ok) bar.style.setProperty("--h", `${Math.max(12, Math.round((c.ms / slowest) * 100))}%`);
      bar.title = c.ok
        ? `${clock(c.t)}, ${c.code}, ${c.ms} ms`
        : `${clock(c.t)}, failed: ${c.err || "no response"}`;
      node.append(bar);
    }
    return node;
  }

  // 7-day uptime against the SLO, and how much error budget is left.
  function slo(m, state) {
    const s = m.slo;
    const node = el("div", { class: "slo" });
    if (!s) {
      node.append(el("p", { class: "figure", text: "–" }), el("p", { class: "slo-note", text: "no checks yet" }));
      return node;
    }
    const left = s.budget_left;
    const level = left <= 0 ? "spent" : left < 25 ? "low" : "ok";
    const uptime = s.uptime >= 99.995 ? "100" : s.uptime.toFixed(s.uptime >= 99 ? 2 : 1);
    const bar = el("span", { class: `budget is-${level}`, role: "img", "aria-label": `Error budget ${left}% left` });
    const fill = el("span", { class: "budget-fill" });
    fill.style.setProperty("--left", `${Math.max(0, left)}%`);
    bar.append(fill);
    bar.title = `${s.failed} failed of ${s.checks} checks in 7 days; the ${s.target}% SLO allows ${(s.checks * (100 - s.target) / 100).toFixed(1)}`;
    node.append(
      el("p", { class: state === "down" || level === "spent" ? "figure is-down" : "figure" }, [
        document.createTextNode(`${uptime}%`),
        el("small", { text: `7 days, SLO ${s.target}%` }),
      ]),
      bar,
      el("p", { class: `slo-note is-${level}`, text: level === "spent" ? "Error budget spent" : `Budget ${Math.floor(left)}% left` }),
    );
    return node;
  }

  function row(m) {
    const state = stateOf(m);
    const link = el("a", { class: "site-url", href: m.url, rel: "noopener noreferrer nofollow", target: "_blank", text: m.url.replace(/^https?:\/\//, "") });
    const id = el("div", { class: "site-id" }, [
      el("p", { class: "site-name" }, [el("span", { class: "dot", "aria-hidden": "true" }), el("span", { text: m.name })]),
      link,
      el("p", { class: "site-settings", text: `${m.method}, ${INTERVAL_LABEL[m.interval] || `every ${m.interval}s`}${m.alert ? ", pages on-call" : ""}` }),
    ]);

    const uptime = slo(m, state);

    const p95 = m.p95_latency_ms == null ? "" : `p95 ${m.p95_latency_ms} ms, `;
    let last;
    if (!m.last) {
      last = el("p", { class: "last" }, [document.createTextNode("Waiting"), el("small", { text: "first check soon" })]);
    } else if (m.last.ok) {
      last = el("p", { class: "last" }, [
        document.createTextNode(`${m.last.latency_ms} ms`),
        el("small", { text: `${p95}${m.last.status_code}, ${ago(m.last.at)}` }),
      ]);
    } else {
      last = el("p", { class: "last is-down" }, [
        document.createTextNode(m.last.error || "Failed"),
        el("small", { text: ago(m.last.at) }),
      ]);
    }

    const children = [id, strip(m), uptime, last];
    if (tokens[m.id]) {
      const remove = el("button", { class: "remove", type: "button", "aria-label": `Remove ${m.name}`, title: "Remove", text: "×" });
      remove.addEventListener("click", () => removeMonitor(m));
      children.push(remove);
    } else {
      children.push(el("span", { "aria-hidden": "true" }));
    }
    return el("li", { class: "site", dataset: { state } }, children);
  }

  function headline(monitors) {
    const checked = monitors.filter((m) => m.last);
    const down = checked.filter((m) => !m.last.ok);
    let text;
    let state;
    if (!monitors.length) { text = "The board is empty"; state = "pending"; }
    else if (!checked.length) { text = "Running the first checks"; state = "pending"; }
    else if (down.length === 0) {
      text = checked.length === 1 ? "The one site is up" : `All ${checked.length} sites are up`;
      state = "up";
    } else {
      text = checked.length === 1
        ? "The one site is down"
        : `${down.length} of ${checked.length} sites ${down.length === 1 ? "is" : "are"} down`;
      state = "down";
    }
    $("headline").textContent = text;
    document.body.dataset.state = state;
    document.title = state === "down" ? `${text} · Uptime board` : "Uptime board";
  }

  function render(data) {
    const monitors = data.monitors || [];
    // Forget tokens for monitors that expired or were removed elsewhere.
    const ids = new Set(monitors.map((m) => String(m.id)));
    for (const key of Object.keys(tokens)) if (!ids.has(key)) delete tokens[key];
    saveTokens(tokens);

    headline(monitors);
    board.replaceChildren(...monitors.map(row));
    $("board-empty").hidden = monitors.length > 0;
    $("board-error").hidden = true;
    $("board-meta").textContent = `${monitors.length} of ${data.max} places used, refreshes every 10 seconds`;
  }

  async function refresh() {
    try {
      const res = await fetch("/api/monitors", { headers: { Accept: "application/json" } });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      render(await res.json());
    } catch {
      $("board-error").hidden = false;
      $("board-error").textContent = "The board could not be loaded. Retrying in 10 seconds.";
    }
  }

  // --- Actions -----------------------------------------------------------------
  function say(text, kind) {
    message.textContent = text;
    message.className = `form-message ${kind ? `is-${kind}` : ""}`;
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = $("add-button");
    const url = $("url").value.trim();
    if (!url) { say("Enter the address of a site to watch.", "error"); $("url").focus(); return; }

    button.disabled = true;
    say("Checking that address…");
    try {
      const res = await fetch("/api/monitors", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({
          url,
          name: $("name").value.trim(),
          method: $("method").value,
          interval: Number($("interval").value),
        }),
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) {
        // A 403 without a JSON error comes from the web application firewall.
        const blocked = res.status === 403 && !body.error;
        say(blocked ? "The firewall blocked that address. Try a public website." : body.error || `Could not add it (HTTP ${res.status}).`, "error");
        return;
      }
      tokens[body.id] = body.token;
      saveTokens(tokens);
      form.reset();
      $("interval").value = "300";
      say("Added. The first check runs within a few seconds.", "ok");
      await refresh();
    } catch {
      say("Could not reach the board. Check your connection and try again.", "error");
    } finally {
      button.disabled = false;
    }
  });

  async function removeMonitor(m) {
    if (!window.confirm(`Remove ${m.name} from the board?`)) return;
    const res = await fetch(`/api/monitors/${m.id}`, {
      method: "DELETE",
      headers: { "X-Delete-Token": tokens[m.id] || "", Accept: "application/json" },
    }).catch(() => null);
    if (res && res.ok) {
      delete tokens[m.id];
      saveTokens(tokens);
      say(`Removed ${m.name}.`, "ok");
    } else {
      say("Could not remove it. Only the browser that added a site can remove it.", "error");
    }
    refresh();
  }

  refresh();
  setInterval(() => { if (!document.hidden) refresh(); }, POLL_MS);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
})();
