/* StreamForge Sync — web admin. Plain JS, no build step, no external resources. */
(() => {
  "use strict";

  const TOKEN_KEY = "sf_token";
  const $app = document.getElementById("app");
  const $dialog = document.getElementById("dialog");

  const state = {
    token: sessionGet(TOKEN_KEY),
    me: null,       // {user, device, server}
    setup: null,    // {needsSetup, openSignup, name, version}
  };

  function sessionGet(k) { try { return sessionStorage.getItem(k); } catch { return null; } }
  function sessionSet(k, v) { try { v == null ? sessionStorage.removeItem(k) : sessionStorage.setItem(k, v); } catch { /* ignore */ } }

  // ---------- DOM helper (never uses innerHTML for data) ----------
  function h(tag, attrs, ...children) {
    const el = document.createElementNS(tag === "svg" || tag === "path" || tag === "rect" || tag === "circle" || tag === "line" || tag === "polyline" ? "http://www.w3.org/2000/svg" : "http://www.w3.org/1999/xhtml", tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v == null || v === false) continue;
        if (k === "class") el.setAttribute("class", v);
        else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v);
        else if (k === "value") el.value = v;
        else if (k === "checked") el.checked = !!v;
        else el.setAttribute(k, v === true ? "" : String(v));
      }
    }
    for (const c of children.flat(Infinity)) {
      if (c == null || c === false) continue;
      el.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return el;
  }

  const ICONS = {
    backups: "M4 4h16v16H4zM8 4v6h8V4M8 16h8",
    overview: "M3 13h8V3H3zM13 21h8V11h-8zM3 21h8v-6H3zM13 3v6h8V3z",
    devices: "M4 5h16v10H4zM2 19h20M9 15v4M15 15v4",
    pair: "M3 6h18v11H3zM8 21h8M12 17v4M9 10.5h6",
    users: "M16 19v-1a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v1M9 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM22 19v-1a4 4 0 0 0-3-3.9M16 3.1a3.5 3.5 0 0 1 0 6.8",
    activity: "M22 12h-4l-3 8L9 4l-3 8H2",
    dispatcharr: "M3 4h18v6H3zM3 14h18v6H3zM7 7h.01M7 17h.01M11 7h6M11 17h6",
    addons: "M9 3h6v3.5a1.5 1.5 0 0 0 3 0V6h3v6h-.5a1.5 1.5 0 0 0 0 3h.5v6h-6v-.5a1.5 1.5 0 0 0-3 0v.5H6v-6h-.5a1.5 1.5 0 0 1 0-3H6V6h3z",
    defaults: "M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1M15 4v4M9 10v4M17 16v4",
    account: "M12 12a4.5 4.5 0 1 0 0-9 4.5 4.5 0 0 0 0 9zM4 21a8 8 0 0 1 16 0",
    logout: "M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4M10 17l5-5-5-5M15 12H3",
    ios: "M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2",
    ipados: "M6 2h12a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2",
    android: "M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2",
    tvos: "M3 5h18v12H3zM8 21h8M12 17v4",
    androidtv: "M3 5h18v12H3zM8 21h8M12 17v4",
    web: "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM2 12h20M12 2a15 15 0 0 1 0 20M12 2a15 15 0 0 0 0 20",
    unknown: "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 16v.01M12 13a2 2 0 1 0-2-2",
  };
  function icon(name) {
    return h("svg", { viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": "1.8", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true" },
      h("path", { d: ICONS[name] || ICONS.unknown }));
  }
  function brandMark(cls) {
    return h("img", { class: cls || "brand-mark", src: "/icon.svg", alt: "" });
  }

  const PLATFORM_NAMES = { ios: "iPhone", ipados: "iPad", tvos: "Apple TV", android: "Android", androidtv: "Android TV", web: "Web browser" };
  const SCOPES = [
    { id: "read", label: "Read", hint: "Pull library & progress" },
    { id: "write", label: "Write", hint: "Push changes" },
    { id: "secrets", label: "Secrets", hint: "Passwords, API keys, PINs" },
  ];

  // ---------- formatting ----------
  const rtf = typeof Intl !== "undefined" && Intl.RelativeTimeFormat ? new Intl.RelativeTimeFormat(undefined, { numeric: "auto" }) : null;
  function ago(ms) {
    if (!ms) return "never";
    const diff = (ms - Date.now()) / 1000;
    const abs = Math.abs(diff);
    if (abs < 45) return "just now";
    const units = [["minute", 60], ["hour", 3600], ["day", 86400], ["week", 604800], ["month", 2629800], ["year", 31557600]];
    let u = units[0];
    for (const x of units) if (abs >= x[1]) u = x;
    const v = Math.round(diff / u[1]);
    return rtf ? rtf.format(v, u[0]) : `${Math.abs(v)} ${u[0]}s ago`;
  }
  function fullDate(ms) { return ms ? new Date(ms).toLocaleString() : "—"; }
  function timeEl(ms) { return h("time", { datetime: ms ? new Date(ms).toISOString() : null, title: fullDate(ms) }, ago(ms)); }
  function num(n) { return (n || 0).toLocaleString(); }

  // ---------- API ----------
  class ApiError extends Error {
    constructor(msg, code, status) { super(msg); this.code = code; this.status = status; }
  }
  async function api(method, path, body) {
    const headers = {};
    if (state.token) headers.Authorization = "Bearer " + state.token;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    let res;
    try {
      res = await fetch(path, { method, headers, body: body !== undefined ? JSON.stringify(body) : undefined, credentials: "omit", cache: "no-store" });
    } catch (e) {
      throw new ApiError("Can't reach the server.", "network", 0);
    }
    if (res.status === 204) return null;
    let data = null;
    try { data = await res.json(); } catch { /* not JSON */ }
    if (!res.ok) {
      if (res.status === 401 && state.token && !path.startsWith("/api/auth/")) {
        signedOut("Your session ended. Sign in again.");
      }
      if (res.status === 429) {
        const ra = parseInt(res.headers.get("Retry-After") || "0", 10);
        throw new ApiError(`Too many attempts. Try again in ${Math.max(1, Math.ceil(ra / 60))} min.`, "rate_limited", 429);
      }
      throw new ApiError((data && data.error) || res.statusText || "Request failed", data && data.code, res.status);
    }
    return data;
  }

  // ---------- toasts & dialogs ----------
  function toast(msg, kind) {
    const el = h("div", { class: "toast " + (kind || "") }, msg);
    document.getElementById("toasts").append(el);
    setTimeout(() => el.remove(), kind === "error" ? 6000 : 3500);
  }
  function showDialog(build) {
    return new Promise((resolve) => {
      $dialog.replaceChildren();
      const close = (v) => { $dialog.close(); resolve(v); };
      $dialog.append(build(close));
      $dialog.onclose = () => resolve(undefined);
      $dialog.onclick = (e) => { if (e.target === $dialog) close(undefined); };
      $dialog.showModal();
      const first = $dialog.querySelector("input, select, button.primary, button.danger");
      if (first) first.focus();
    });
  }
  function confirmDialog(title, text, okLabel, danger) {
    return showDialog((close) => h("div", { class: "dlg" },
      h("h3", null, title), h("p", null, text),
      h("div", { class: "btns" },
        h("button", { class: "btn ghost", onclick: () => close(false) }, "Cancel"),
        h("button", { class: "btn " + (danger ? "danger" : "primary"), onclick: () => close(true) }, okLabel))));
  }
  function promptDialog(title, text, field) {
    return showDialog((close) => {
      const input = h("input", { class: "input", type: field.type || "text", value: field.value || "", placeholder: field.placeholder || "", autocomplete: field.autocomplete || "off", minlength: field.minlength, required: true });
      const form = h("form", { class: "dlg", onsubmit: (e) => { e.preventDefault(); close(input.value); } },
        h("h3", null, title), text ? h("p", null, text) : null,
        h("label", { class: "field" }, h("span", null, field.label), input),
        h("div", { class: "btns" },
          h("button", { type: "button", class: "btn ghost", onclick: () => close(undefined) }, "Cancel"),
          h("button", { type: "submit", class: "btn primary" }, field.ok || "Save")));
      return form;
    });
  }

  function busy(btn, fn) {
    return async (...args) => {
      if (btn.disabled) return;
      btn.disabled = true;
      try { await fn(...args); } finally { btn.disabled = false; }
    };
  }

  // ---------- auth flows ----------
  function signedOut(msg) {
    state.token = null; state.me = null;
    sessionSet(TOKEN_KEY, null);
    if (msg) toast(msg);
    render();
  }
  async function signIn(token) {
    state.token = token;
    sessionSet(TOKEN_KEY, token);
    if (state.setup) state.setup.needsSetup = false;
    state.me = await api("GET", "/api/me");
    if (!location.hash || location.hash === "#/") location.hash = "#/overview";
    render();
  }
  async function signOut() {
    try { await api("POST", "/api/auth/logout"); } catch { /* token may already be gone */ }
    signedOut("Signed out.");
  }

  function authCard(title, lead, form) {
    const name = (state.setup && state.setup.name) || "StreamForge Sync";
    return h("div", { class: "auth" },
      h("div", { class: "auth-card" },
        h("div", { class: "brand" }, brandMark(), h("div", null, h("div", { class: "brand-name" }, name))),
        h("h1", null, title), h("p", { class: "lead" }, lead), form,
        h("div", { class: "auth-foot" }, "StreamForge Sync ", (state.setup && state.setup.version) || "")));
  }

  function viewSetup() {
    const err = h("div", { class: "form-error" });
    const u = h("input", { class: "input", name: "username", autocomplete: "username", required: true, autofocus: true, placeholder: "e.g. mo" });
    const p1 = h("input", { class: "input", type: "password", autocomplete: "new-password", required: true, minlength: 8 });
    const p2 = h("input", { class: "input", type: "password", autocomplete: "new-password", required: true, minlength: 8 });
    const btn = h("button", { class: "btn primary block", type: "submit" }, "Create admin account");
    const form = h("form", {
      onsubmit: (e) => { e.preventDefault(); submit(); },
    },
      h("label", { class: "field" }, h("span", null, "Username"), u),
      h("label", { class: "field" }, h("span", null, "Password"), p1),
      h("label", { class: "field" }, h("span", null, "Confirm password"), p2),
      err, btn);
    const submit = busy(btn, async () => {
      err.textContent = "";
      if (p1.value !== p2.value) { err.textContent = "Passwords don't match."; return; }
      try {
        const r = await api("POST", "/api/setup", { username: u.value.trim(), password: p1.value, device: { name: browserName(), platform: "web" } });
        await signIn(r.token);
        toast("Welcome! Your server is ready.", "ok");
      } catch (e) { err.textContent = e.message; }
    });
    return authCard("Set up your server", "Create the first account. It will be the administrator.", form);
  }

  function viewSignIn() {
    const err = h("div", { class: "form-error" });
    const u = h("input", { class: "input", autocomplete: "username", required: true, autofocus: true });
    const p = h("input", { class: "input", type: "password", autocomplete: "current-password", required: true });
    const btn = h("button", { class: "btn primary block", type: "submit" }, "Sign in");
    const form = h("form", { onsubmit: (e) => { e.preventDefault(); submit(); } },
      h("label", { class: "field" }, h("span", null, "Username"), u),
      h("label", { class: "field" }, h("span", null, "Password"), p),
      err, btn);
    const submit = busy(btn, async () => {
      err.textContent = "";
      try {
        const r = await api("POST", "/api/auth/login", { username: u.value.trim(), password: p.value, device: { name: browserName(), platform: "web" } });
        await signIn(r.token);
      } catch (e) { err.textContent = e.message; p.select(); }
    });
    return authCard("Sign in", "Manage devices, pair a TV and control access.", form);
  }

  function browserName() {
    const ua = navigator.userAgent;
    const b = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Browser";
    const os = /iPhone|iPad/.test(ua) ? "iOS" : /Android/.test(ua) ? "Android" : /Mac OS X/.test(ua) ? "macOS" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
    return `Web admin · ${b}${os ? " on " + os : ""}`;
  }

  // ---------- shell ----------
  const ROUTES = [
    { id: "overview", label: "Overview", view: viewOverview },
    { id: "backups", label: "Backups", view: viewBackups, admin: true },
    { id: "devices", label: "Devices", view: viewDevices },
    { id: "pair", label: "Pair a TV", view: viewPair },
    { id: "users", label: "Users", view: viewUsers, admin: true },
    { id: "user", label: "User", view: viewUser, admin: true, hidden: true, parent: "users" },
    { id: "dispatcharr", label: "Dispatcharr", view: viewDispatcharr, admin: true },
    { id: "addons", label: "Addons", view: viewAddons, admin: true },
    { id: "defaults", label: "Default settings", view: viewDefaults, admin: true },
    { id: "activity", label: "Activity", view: viewActivity },
    { id: "account", label: "Account", view: viewAccount },
  ];

  function currentRoute() {
    const id = (location.hash.replace(/^#\/?/, "").split("?")[0]) || "overview";
    const isAdmin = state.me && state.me.user.role === "admin";
    return ROUTES.find((r) => r.id === id && (!r.admin || isAdmin)) || ROUTES[0];
  }

  function shell(route, content) {
    const me = state.me;
    const isAdmin = me.user.role === "admin";
    return h("div", { class: "shell" },
      h("aside", { class: "sidebar" },
        h("a", { class: "brand", href: "#/overview" }, brandMark(),
          h("div", null, h("div", { class: "brand-name" }, "StreamForge"), h("div", { class: "brand-sub" }, me.server.name))),
        h("nav", { class: "nav", "aria-label": "Main" },
          ROUTES.filter((r) => (!r.admin || isAdmin) && !r.hidden).map((r) => {
            const active = r.id === (route.parent || route.id);
            return h("a", { href: "#/" + r.id, class: active ? "active" : null, "aria-current": active ? "page" : null }, icon(r.id), r.label);
          })),
        h("div", { class: "sidebar-foot" },
          h("div", { class: "avatar", "aria-hidden": "true" }, me.user.username.slice(0, 1).toUpperCase()),
          h("div", { class: "who" }, h("b", null, me.user.username), h("small", null, me.user.role === "admin" ? "Administrator" : "Member")),
          h("button", { class: "btn ghost sm", title: "Sign out", "aria-label": "Sign out", onclick: signOut }, icon("logout")))),
      h("main", { class: "main" }, content));
  }

  function pageHead(title, sub, actions) {
    return h("div", { class: "page-head" }, h("div", null, h("h1", null, title), sub ? h("p", null, sub) : null), actions || null);
  }

  // ---------- Overview ----------
  function viewOverview() {
    const root = h("div", null, pageHead("Overview", "What's synced for your account on " + state.me.server.name + "."));
    const body = h("div", null, h("div", { class: "card" }, h("div", { class: "empty" }, "Loading…")));
    root.append(body);
    if (state.me.user.role === "admin") root.prepend(operationsPanel());
    (async () => {
      try {
        const [s, d] = await Promise.all([api("GET", "/api/stats"), api("GET", "/api/devices")]);
        const max = Math.max(1, ...s.collections.map((c) => c.count + c.deleted));
        const bars = s.collections.length ? h("div", { class: "bars" }, s.collections.map((c) => {
          const fill = h("div", { class: "bar-fill" });
          fill.style.width = Math.max(1, (c.count / max) * 100) + "%";
          return h("div", { class: "bar-row" },
            h("div", { class: "name", title: c.collection }, c.collection),
            h("div", { class: "bar-track" }, fill),
            h("div", { class: "num" }, num(c.count), c.deleted ? h("small", null, num(c.deleted) + " deleted") : null));
        })) : h("div", { class: "empty" }, "Nothing synced yet. Sign in from the StreamForge app to start syncing.");
        const lastDevice = d.devices.filter((x) => x.platform !== "web").sort((a, b) => b.lastSeenAt - a.lastSeenAt)[0];
        body.replaceChildren(
          h("div", { class: "stats" },
            stat("Records", num(s.records), "across " + s.collections.length + " collections"),
            stat("Devices", num(s.devices), lastDevice ? "latest: " + lastDevice.name : "none paired yet"),
            stat("Last sync", s.lastSyncAt ? ago(s.lastSyncAt) : "never", s.lastSyncAt ? fullDate(s.lastSyncAt) : ""),
            stat("Revision", num(s.rev), "server change counter")),
          h("div", { class: "card" }, h("h2", null, "Collections"), h("p", { class: "sub" }, "Live records per collection. Deleted items are kept as tombstones for 180 days."), bars),
          h("div", { class: "card accent" },
            h("div", { class: "row" },
              h("div", { class: "field" }, h("h2", null, "Got a TV?"), h("p", { class: "sub" }, "Pair an Apple TV or Android TV with a short code — no typing passwords with a remote.")),
              h("a", { class: "btn primary", href: "#/pair" }, "Pair a TV"))));
      } catch (e) { body.replaceChildren(h("div", { class: "card" }, h("div", { class: "empty" }, e.message))); }
    })();
    return root;
  }
  function stat(label, value, hint) {
    return h("div", { class: "stat" }, h("div", { class: "label" }, label), h("div", { class: "value" }, value), h("div", { class: "hint" }, hint));
  }

  function operationsPanel() {
    const panel = h("div", { class: "card" }, h("h2", null, "Server health"), h("p", null, "Checking…"));
    api("GET", "/api/admin/operations").then(s => panel.replaceChildren(
      h("div", { class: "card-head" }, h("h2", null, "Server health"), h("span", { class: "badge accent" }, "Database healthy · " + s.version)),
      h("div", { class: "stats" }, stat("Users", num(s.users), "server-wide"), stat("Recent devices", num(s.recentDevices), "seen in the last 15 minutes"),
        stat("Storage", (s.databaseBytes / 1048576).toFixed(1) + " MB", "database and write-ahead log"),
        stat("Last backup", s.lastBackupAt ? ago(s.lastBackupAt) : "None", "7 snapshots retained")),
      h("div", { class: "btns" }, h("a", { class: "btn", href: "#/backups" }, "Manage backups"),
        h("a", { class: "btn", href: "#/dispatcharr" }, "Test providers"), h("a", { class: "btn", href: "#/devices" }, "Device health")),
      h("p", { class: "sub" }, "Recent activity indicates contact with the server, not whether a device is watching.")))
      .catch(e => panel.replaceChildren(h("h2", null, "Server health"), h("p", { role: "alert" }, e.message)));
    return panel;
  }

  function providerTestButton(path) {
    const result = h("span", { class: "small muted", role: "status", "aria-live": "polite" });
    const button = h("button", { class: "btn sm", type: "button" }, "Test connection");
    button.addEventListener("click", busy(button, async () => {
      result.textContent = "Testing…";
      try { const r = await api("POST", path, {}); result.textContent = r.message + " (" + r.latencyMs + " ms)"; }
      catch(e) { result.textContent = e.message; }
    }));
    return h("div", null, button, result);
  }

  function viewBackups() {
    const list = h("div", null, loadingCard());
    const status = h("p", { role: "status", "aria-live": "polite" });
    const create = h("button", { class: "btn primary", type: "button" }, "Create backup");
    const daily = h("input", { type: "checkbox", class: "chk" });
    create.addEventListener("click", busy(create, async () => {
      status.textContent = "Creating a consistent snapshot…";
      try { await api("POST", "/api/admin/backups", {}); status.textContent = "Backup ready."; await load(); }
      catch(e) { status.textContent = e.message; }
    }));
    daily.addEventListener("change", async () => {
      daily.disabled = true;
      try { await api("PUT", "/api/admin/backups/schedule", { daily: daily.checked }); status.textContent = daily.checked ? "Daily backups enabled. The hourly scheduler creates the next due snapshot." : "Daily backups disabled."; }
      catch(e) { daily.checked = !daily.checked; status.textContent = e.message; }
      finally { daily.disabled = false; }
    });
    async function download(name, button) {
      button.disabled = true;
      try {
        const r = await fetch("/api/admin/backups/" + enc(name), { headers: { Authorization: "Bearer " + state.token }, cache: "no-store", credentials: "omit" });
        if (!r.ok) throw new Error("Download failed. Check your session and Secrets scope.");
        const url = URL.createObjectURL(await r.blob());
        const a = h("a", { href: url, download: name }); document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 30000);
      } catch(e) { status.textContent = e.message; }
      finally { button.disabled = false; }
    }
    async function load() {
      try {
        const r = await api("GET", "/api/admin/backups"); daily.checked = r.daily;
        list.replaceChildren(...(r.backups.length ? r.backups.map(b => {
          const button = h("button", { class: "btn", type: "button" }, "Download");
          button.addEventListener("click", () => download(b.name, button));
          return h("div", { class: "card" }, h("div", { class: "card-head" },
            h("div", null, h("h3", null, fullDate(b.createdAt)), h("p", { class: "sub" }, (b.size/1048576).toFixed(1) + " MB · " + b.name)), button));
        }) : [messageCard("No backups yet. Create your first snapshot above.")]));
      } catch(e) { list.replaceChildren(messageCard(e.message)); create.disabled = daily.disabled = true; }
    }
    load();
    return h("div", null, pageHead("Backups", "Database and matching encryption key. The newest seven snapshots are retained."),
      h("div", { class: "card" }, h("div", { class: "btns" }, create, h("label", null, daily, " Daily backups")), status,
        h("p", { class: "sub" }, "Backups contain credentials and sign-in tokens. Store downloaded archives privately. Keep a copy outside this server.")),
      list, h("div", { class: "card" }, h("h2", null, "Restore a backup"),
        h("ol", null,
          h("li", null, "Download the chosen ZIP and keep a separate copy of your current data directory."),
          h("li", null, "Stop StreamForge Sync. Never replace an open database."),
          h("li", null, "Extract streamforge.db and secret.key together into a new, empty private data directory. Do not copy old -wal or -shm files."),
          h("li", null, "Point STREAMFORGE_DATA (or the Docker /data volume) at that directory and start the server with the same or a newer version."),
          h("li", null, "Verify /healthz, sign in, and check users and provider connections. Clients will reconcile on their next sync.")),
        h("p", { class: "sub" }, "Restoring also restores tokens and permissions from that snapshot. Revoke any devices that should no longer have access.")));
  }

  // ---------- Devices ----------
  function viewDevices() {
    const isAdmin = state.me.user.role === "admin";
    let targetUser = new URLSearchParams(location.hash.split("?")[1] || "").get("user") || "";
    const list = h("div", { class: "devices" }, h("div", { class: "card" }, h("div", { class: "empty" }, "Loading…")));
    const toolbar = h("div", { class: "toolbar" }, h("a", { class: "btn primary", href: "#/pair" }, icon("pair"), "Pair a TV"));
    const root = h("div", null, pageHead("Devices", "Every app or browser signed in to your account. Revoke anything you don't recognise.", toolbar), list);

    if (isAdmin) {
      const sel = h("select", { class: "input", "aria-label": "Show devices of user", onchange: () => { targetUser = sel.value; location.hash = "#/devices" + (sel.value ? "?user=" + encodeURIComponent(sel.value) : ""); } },
        h("option", { value: "" }, "My devices"));
      toolbar.prepend(sel);
      api("GET", "/api/users").then((r) => {
        for (const u of r.users) if (u.id !== state.me.user.id) sel.append(h("option", { value: u.id }, u.username + "'s devices"));
        sel.value = targetUser;
      }).catch(() => {});
    }

    async function load() {
      try {
        const r = await api("GET", "/api/devices" + (targetUser ? "?user=" + encodeURIComponent(targetUser) : ""));
        const devs = r.devices.sort((a, b) => (b.current - a.current) || (b.lastSeenAt - a.lastSeenAt));
        list.replaceChildren(...(devs.length ? devs.map(deviceCard) : [h("div", { class: "card" }, h("div", { class: "empty" }, "No devices."))]));
      } catch (e) { list.replaceChildren(h("div", { class: "card" }, h("div", { class: "empty" }, e.message))); }
    }

    function deviceCard(d) {
      const titleBox = h("div", { class: "device-title" });
      const renderTitle = () => titleBox.replaceChildren(
        h("span", null, d.name),
        d.current ? h("span", { class: "badge accent" }, "This device") : null);
      renderTitle();

      const scopeBtns = SCOPES.map((s) => {
        const b = h("button", { class: "scope" + (d.scopes.includes(s.id) ? " on" : ""), type: "button", title: s.hint, "aria-pressed": String(d.scopes.includes(s.id)) }, s.label);
        b.addEventListener("click", busy(b, async () => {
          const next = d.scopes.includes(s.id) ? d.scopes.filter((x) => x !== s.id) : d.scopes.concat(s.id);
          if (!next.length) { toast("A device needs at least one scope — revoke it instead.", "error"); return; }
          if (d.current && !next.includes("read")) {
            const ok = await confirmDialog("Restrict this browser?", "Removing scopes from the device you're using can lock you out of features here.", "Restrict", true);
            if (!ok) return;
          }
          try {
            const upd = await api("PATCH", "/api/devices/" + encodeURIComponent(d.id), { scopes: next });
            Object.assign(d, upd);
            scopeBtns.forEach((btn, i) => { const on = d.scopes.includes(SCOPES[i].id); btn.classList.toggle("on", on); btn.setAttribute("aria-pressed", String(on)); });
            toast("Access updated for " + d.name + ".", "ok");
          } catch (e) { toast(e.message, "error"); }
        }));
        return b;
      });

      const renameBtn = h("button", { class: "btn sm", type: "button" }, "Rename");
      renameBtn.addEventListener("click", async () => {
        const name = await promptDialog("Rename device", null, { label: "Name", value: d.name, ok: "Rename" });
        if (name == null || !name.trim() || name.trim() === d.name) return;
        try {
          const upd = await api("PATCH", "/api/devices/" + encodeURIComponent(d.id), { name: name.trim() });
          Object.assign(d, upd); renderTitle(); toast("Renamed.", "ok");
        } catch (e) { toast(e.message, "error"); }
      });
      const revokeBtn = h("button", { class: "btn sm danger", type: "button" }, "Revoke");
      revokeBtn.addEventListener("click", async () => {
        const ok = await confirmDialog("Revoke " + d.name + "?",
          d.current ? "This signs out this browser." : "The device is signed out immediately. Its local data stays on the device; it just stops syncing.",
          "Revoke", true);
        if (!ok) return;
        try {
          await api("DELETE", "/api/devices/" + encodeURIComponent(d.id));
          if (d.current) { signedOut("This browser was signed out."); return; }
          toast(d.name + " revoked.", "ok"); load();
        } catch (e) { toast(e.message, "error"); }
      });

      return h("div", { class: "device" + (d.current ? " current" : "") },
        h("div", { class: "device-icon" }, icon(d.platform)),
        h("div", { class: "info" }, titleBox,
          h("div", { class: "device-meta" },
            h("span", null, PLATFORM_NAMES[d.platform] || d.platform),
            h("span", { class: "badge" }, Date.now() - d.lastSeenAt < 900000 ? "Seen recently" : "Inactive"),
            h("span", null, "last seen ", timeEl(d.lastSeenAt)),
            h("span", null, "last successful sync: ", d.lastSyncAt ? timeEl(d.lastSyncAt) : "not recorded"),
            d.lastIp ? h("span", { class: "mono" }, d.lastIp) : null,
            h("span", null, "added ", timeEl(d.createdAt)))),
        h("div", { class: "device-actions" },
          h("div", { class: "scopes", role: "group", "aria-label": "Access scopes" }, scopeBtns),
          h("div", { class: "btns" }, renameBtn, revokeBtn)));
    }

    load();
    return root;
  }

  // ---------- Pair a TV ----------
  function viewPair() {
    const err = h("div", { class: "form-error" });
    const code = h("input", { class: "input code-input", maxlength: 7, placeholder: "K7Q-4MX", autocomplete: "off", autocapitalize: "characters", spellcheck: "false", "aria-label": "Pairing code", required: true, autofocus: true });
    code.addEventListener("input", () => {
      let v = code.value.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6);
      if (v.length > 3) v = v.slice(0, 3) + "-" + v.slice(3);
      code.value = v;
    });
    const mine = state.me.device.scopes;
    const checks = SCOPES.map((s) => {
      const id = "scope-" + s.id;
      const allowed = mine.includes(s.id);
      return h("div", { class: "check-pill" },
        h("input", { type: "checkbox", id, value: s.id, checked: allowed, disabled: !allowed }),
        h("label", { for: id, title: allowed ? "" : "This browser doesn't have this scope" }, h("b", null, s.label), h("small", null, s.hint)));
    });
    const btn = h("button", { class: "btn primary", type: "submit" }, "Approve TV");
    const result = h("div");
    const form = h("form", { onsubmit: (e) => { e.preventDefault(); submit(); } },
      h("label", { class: "field" }, h("span", null, "Code shown on the TV"), code),
      h("div", { class: "field" }, h("span", null, "Allow this TV to"), h("div", { class: "check-pills" }, checks)),
      err, btn, result);
    const submit = busy(btn, async () => {
      err.textContent = "";
      const scopes = checks.map((c) => c.querySelector("input")).filter((i) => i.checked).map((i) => i.value);
      if (!scopes.length) { err.textContent = "Choose at least one permission."; return; }
      try {
        const r = await api("POST", "/api/pair/approve", { code: code.value, scopes });
        code.value = "";
        result.replaceChildren(h("div", { class: "card accent" },
          h("h2", null, "✓ " + r.device.name + " is paired"),
          h("p", { class: "sub" }, "The TV will sign in within a couple of seconds with: " + r.device.scopes.join(", ") + "."),
          h("a", { class: "btn sm", href: "#/devices" }, "View devices")));
        toast(r.device.name + " paired.", "ok");
      } catch (e) {
        err.textContent = e.code === "invalid_code" ? "That code doesn't match a TV waiting to pair. Check it and try again."
          : e.code === "expired" ? "That code expired. Start pairing again on the TV." : e.message;
      }
    });
    return h("div", null,
      pageHead("Pair a TV", "Sign in an Apple TV or Android TV without typing a password with the remote."),
      h("div", { class: "card" },
        h("div", { class: "pair-grid" }, form,
          h("div", null, h("h2", null, "How it works"),
            h("ol", { class: "steps" },
              h("li", null, h("span", null, "On the TV, open StreamForge’s ", h("b", null, "sync settings"), " and choose to ", h("b", null, "pair with a code"), ".")),
              h("li", null, h("span", null, "The TV shows a 6-character code like ", h("b", { class: "mono" }, "K7Q-4MX"), ". It's valid for 10 minutes.")),
              h("li", null, h("span", null, "Type it here, choose what the TV may access, and approve.")),
              h("li", null, h("span", null, "Leave ", h("b", null, "Secrets"), " off for shared or kids' TVs — they'll never receive passwords, API keys or PINs.")))))));
  }

  // ---------- Users ----------
  function viewUsers() {
    const tbody = h("tbody", null, h("tr", null, h("td", { colspan: 5, class: "empty" }, "Loading…")));
    const err = h("div", { class: "form-error" });
    const u = h("input", { class: "input", required: true, autocomplete: "off", placeholder: "username" });
    const p = h("input", { class: "input", type: "password", required: true, minlength: 8, autocomplete: "new-password", placeholder: "at least 8 characters" });
    const role = h("select", { class: "input" }, h("option", { value: "member" }, "Member"), h("option", { value: "admin" }, "Admin"));
    const btn = h("button", { class: "btn primary", type: "submit" }, "Create user");
    const assignBox = h("div", { class: "assign-new" });
    const form = h("form", { onsubmit: (e) => { e.preventDefault(); create(); } },
      h("div", { class: "row" },
        h("label", { class: "field" }, h("span", null, "Username"), u),
        h("label", { class: "field" }, h("span", null, "Password"), p),
        h("label", { class: "field" }, h("span", null, "Role"), role),
        btn), assignBox, err);
    let pickers = { servers: () => [], addons: () => [], reset: () => {} };
    const create = busy(btn, async () => {
      err.textContent = "";
      try {
        const body = { username: u.value.trim(), password: p.value, role: role.value };
        const ds = pickers.servers(), ad = pickers.addons();
        if (ds.length) body.dispatcharr = ds;
        if (ad.length) body.addons = ad;
        const nu = await api("POST", "/api/users", body);
        u.value = ""; p.value = ""; role.value = "member"; pickers.reset();
        toast("Created " + nu.username + (ds.length || ad.length ? " with " + plural(ds.length, "server") + " and " + plural(ad.length, "addon") + "." : "."), "ok");
        load();
      } catch (e) { err.textContent = e.message; }
    });
    // Optional: assign Dispatcharr connections and addons right away.
    Promise.all([api("GET", "/api/admin/dispatcharr"), api("GET", "/api/admin/addons")]).then(([ds, lib]) => {
      pickers = newUserPickers(ds.servers, lib.addons);
      assignBox.replaceChildren(pickers.el);
    }).catch(() => {});

    async function load() {
      try {
        const r = await api("GET", "/api/users");
        tbody.replaceChildren(...r.users.map(row));
      } catch (e) { tbody.replaceChildren(h("tr", null, h("td", { colspan: 5, class: "empty" }, e.message))); }
    }
    async function patch(user, body, okMsg) {
      try { await api("PATCH", "/api/users/" + encodeURIComponent(user.id), body); toast(okMsg, "ok"); }
      catch (e) { toast(e.message, "error"); }
      load();
    }
    function row(user) {
      const self = user.id === state.me.user.id;
      const roleSel = h("select", { class: "input", "aria-label": "Role of " + user.username, disabled: self },
        h("option", { value: "member" }, "Member"), h("option", { value: "admin" }, "Admin"));
      roleSel.value = user.role;
      roleSel.addEventListener("change", () => patch(user, { role: roleSel.value }, user.username + " is now " + roleSel.value + "."));
      const resetBtn = h("button", { class: "btn sm", type: "button", onclick: async () => {
        const pw = await promptDialog("Reset password", "Set a new password for " + user.username + ". Their signed-in devices stay signed in.", { label: "New password", type: "password", minlength: 8, autocomplete: "new-password", ok: "Reset" });
        if (pw) patch(user, { password: pw }, "Password reset for " + user.username + ".");
      } }, "Reset password");
      const disBtn = h("button", { class: "btn sm", type: "button", disabled: self, onclick: async () => {
        if (!user.disabled) {
          const ok = await confirmDialog("Disable " + user.username + "?", "They're signed out on every device and can't sign in until re-enabled. Their data is kept.", "Disable", true);
          if (!ok) return;
        }
        patch(user, { disabled: !user.disabled }, user.username + (user.disabled ? " enabled." : " disabled."));
      } }, user.disabled ? "Enable" : "Disable");
      const delBtn = h("button", { class: "btn sm danger", type: "button", disabled: self, onclick: async () => {
        const typed = await promptDialog("Delete " + user.username + "?", "This permanently deletes the account, all its devices and all its synced data. Type the username to confirm.", { label: "Username", ok: "Delete forever" });
        if (typed == null) return;
        if (typed.trim().toLowerCase() !== user.username.toLowerCase()) { toast("Username didn't match — nothing deleted.", "error"); return; }
        try { await api("DELETE", "/api/users/" + encodeURIComponent(user.id)); toast(user.username + " deleted.", "ok"); } catch (e) { toast(e.message, "error"); }
        load();
      } }, "Delete");
      return h("tr", null,
        h("td", null, h("a", { class: "user-link", href: "#/user?id=" + encodeURIComponent(user.id) }, h("b", null, user.username)), self ? h("span", { class: "badge accent" }, " you") : null),
        h("td", null, roleSel),
        h("td", null, user.disabled ? h("span", { class: "badge danger" }, "Disabled") : h("span", { class: "badge ok" }, "Active")),
        h("td", { class: "muted" }, timeEl(user.createdAt)),
        h("td", { class: "actions" },
          h("a", { class: "btn sm", href: "#/user?id=" + encodeURIComponent(user.id) }, "Manage"),
          h("a", { class: "btn sm ghost", href: "#/devices?user=" + encodeURIComponent(user.id) }, "Devices"),
          resetBtn, disBtn, delBtn));
    }
    load();
    return h("div", null,
      pageHead("Users", "Each user has their own completely separate library, progress and settings."),
      h("div", { class: "card" }, h("h2", null, "Add a user"), h("p", { class: "sub" }, "They sign in from the app with this username and password. Default settings and addons for all users are applied automatically."), form),
      h("div", { class: "card" }, h("div", { class: "table-wrap" },
        h("table", null, h("thead", null, h("tr", null, h("th", null, "User"), h("th", null, "Role"), h("th", null, "Status"), h("th", null, "Created"), h("th", null, ""))), tbody))));
  }

  // ---------- managed configuration: shared helpers ----------
  const enc = encodeURIComponent;
  function qparam(name) { return new URLSearchParams(location.hash.split("?")[1] || "").get(name) || ""; }
  function plural(n, word) { return n + " " + word + (n === 1 ? "" : "s"); }
  function loadingCard() { return h("div", { class: "card" }, h("div", { class: "empty" }, "Loading…")); }
  function messageCard(msg) { return h("div", { class: "card" }, h("div", { class: "empty" }, msg)); }

  const AUTH_MODES = [
    { id: "xc", label: "XC (Xtream Codes)", short: "XC" },
    { id: "web", label: "Web account", short: "Web" },
    { id: "apiKey", label: "API key", short: "API key" },
  ];
  function authLabel(m) { const x = AUTH_MODES.find((a) => a.id === m); return x ? x.short : m || "—"; }
  const CRED_FIELDS = [
    { key: "xcPassword", has: "hasXcPassword", label: "XC password" },
    { key: "webPassword", has: "hasWebPassword", label: "Web password" },
    { key: "apiKey", has: "hasApiKey", label: "API key" },
  ];
  function credBadges(x) {
    return h("span", { class: "cred-badges" }, CRED_FIELDS.map((f) =>
      h("span", { class: "badge " + (x[f.has] ? "ok" : ""), title: f.label + (x[f.has] ? " is set" : " is not set") }, f.label.replace(" password", "") + (x[f.has] ? " ✓" : " –"))),
      x.credentialsUnreadable ? h("span", { class: "badge danger", title: "The stored credentials can't be decrypted; enter them again." }, "unreadable") : null);
  }
  function managedBadge(text) { return h("span", { class: "badge managed", title: "Managed by the admin: the user's devices can't change or remove it." }, text || "Managed"); }

  // Credentials dialog for a Dispatcharr assignment. Resolves to the PUT body or undefined.
  // Existing secrets are never shown: blank keeps them, "Clear" removes them.
  function credentialsDialog(title, existing) {
    return showDialog((close) => {
      const mode = h("select", { class: "input" }, AUTH_MODES.map((m) => h("option", { value: m.id }, m.label)));
      mode.value = existing ? existing.authMode : "xc";
      const uname = h("input", { class: "input", value: existing ? existing.username : "", autocomplete: "off", spellcheck: "false", placeholder: "their Dispatcharr username" });
      const fields = CRED_FIELDS.map((f) => {
        const isSet = !!(existing && existing[f.has]);
        const input = h("input", { class: "input", type: "password", autocomplete: "new-password", placeholder: isSet ? "set — leave blank to keep" : "not set" });
        const clear = isSet ? h("input", { type: "checkbox", class: "chk" }) : null;
        const row = h("div", { class: "field" },
          h("span", null, f.label, " ", h("em", { class: "badge " + (isSet ? "ok" : "") }, isSet ? "set" : "not set")),
          input,
          clear ? h("label", { class: "inline-check" }, clear, "Clear the saved value") : null);
        return { f, input, clear, row };
      });
      const hint = h("p", { class: "hint" });
      const sync = () => {
        hint.textContent = mode.value === "xc" ? "XC uses the username and the XC password." : mode.value === "web" ? "Web account uses the username and the web password." : "API key mode only needs the API key.";
        for (const x of fields) x.row.classList.toggle("dim", !(mode.value === "xc" ? x.f.key === "xcPassword" : mode.value === "web" ? x.f.key === "webPassword" : x.f.key === "apiKey"));
      };
      mode.addEventListener("change", sync);
      sync();
      return h("form", { class: "dlg", onsubmit: (e) => {
        e.preventDefault();
        const body = { authMode: mode.value, username: uname.value.trim() };
        for (const x of fields) {
          if (x.input.value) body[x.f.key] = x.input.value;
          else if (x.clear && x.clear.checked) body[x.f.key] = "";
        }
        close(body);
      } },
        h("h3", null, title),
        h("p", null, "Dispatcharr accounts are per person. The credentials are encrypted on the server and only reach this user's devices that have the Secrets scope."),
        h("label", { class: "field" }, h("span", null, "Sign-in method"), mode), hint,
        h("label", { class: "field" }, h("span", null, "Username"), uname),
        fields.map((x) => x.row),
        h("div", { class: "btns" },
          h("button", { type: "button", class: "btn ghost", onclick: () => close(undefined) }, "Cancel"),
          h("button", { type: "submit", class: "btn primary" }, existing ? "Save" : "Assign")));
    });
  }

  // Simple form dialog: fields [{key, label, value, type, placeholder}] → object or undefined.
  function formDialog(title, text, fields, ok) {
    return showDialog((close) => {
      const inputs = fields.map((f) => ({ f, el: h("input", { class: "input", type: f.type || "text", value: f.value == null ? "" : String(f.value), placeholder: f.placeholder || "", autocomplete: "off", required: !!f.required }) }));
      return h("form", { class: "dlg", onsubmit: (e) => {
        e.preventDefault();
        const out = {};
        for (const x of inputs) out[x.f.key] = x.f.type === "number" ? (x.el.value === "" ? null : Number(x.el.value)) : x.el.value.trim();
        close(out);
      } },
        h("h3", null, title), text ? h("p", null, text) : null,
        inputs.map((x) => h("label", { class: "field" }, h("span", null, x.f.label), x.el)),
        h("div", { class: "btns" },
          h("button", { type: "button", class: "btn ghost", onclick: () => close(undefined) }, "Cancel"),
          h("button", { type: "submit", class: "btn primary" }, ok || "Save")));
    });
  }

  function addonLogo(logo) {
    return logo ? h("img", { class: "addon-logo", src: logo, alt: "" }) : h("div", { class: "addon-logo ph", "aria-hidden": "true" }, icon("addons"));
  }

  function fmtSetting(v) {
    if (v === null || v === undefined) return "—";
    if (v === true) return "On";
    if (v === false) return "Off";
    if (v === "") return "(empty)";
    return String(v);
  }

  // One editable control per synced settings key. initial === null means "not managed".
  function settingControl(spec, initial) {
    let el, read;
    if (spec.type === "bool" || spec.type === "enum") {
      const opts = spec.type === "bool" ? [["", "— not set"], ["true", "On"], ["false", "Off"]] : [["", "— not set"]].concat(spec.options.map((o) => [o, o]));
      el = h("select", { class: "input", "aria-label": spec.label }, opts.map(([v, l]) => h("option", { value: v }, l)));
      el.value = initial === null ? "" : String(initial);
      read = () => el.value === "" ? null : spec.type === "bool" ? el.value === "true" : el.value;
    } else if (spec.type === "int" || spec.type === "number") {
      el = h("input", { class: "input", type: "number", "aria-label": spec.label, step: spec.type === "int" ? "1" : "0.05", min: spec.min, max: spec.max, placeholder: "— not set" });
      el.value = initial === null ? "" : String(initial);
      read = () => el.value === "" ? null : Number(el.value);
    } else {
      el = h("input", { class: "input", type: "text", "aria-label": spec.label, placeholder: "— not set", spellcheck: "false" });
      el.value = initial === null ? "" : String(initial);
      read = () => el.value === "" ? null : el.value;
    }
    return { el, read, initial };
  }

  // rows: [{spec, current?, managedValue (null = not managed)}]. Returns {el, changes()}.
  function settingsEditor(rows, showCurrent) {
    const controls = rows.map((r) => ({ r, c: settingControl(r.spec, r.managedValue) }));
    const tbody = h("tbody", null, controls.map(({ r, c }) => h("tr", null,
      h("td", null, h("div", null, r.spec.label), h("div", { class: "mono muted small" }, r.spec.key)),
      showCurrent ? h("td", { class: "muted" }, fmtSetting(r.current)) : null,
      h("td", { class: "setting-input" }, c.el),
      h("td", null, r.managedValue !== null ? managedBadge(showCurrent ? "Locked" : "Default") : null))));
    const el = h("div", { class: "table-wrap" }, h("table", { class: "settings-table" },
      h("thead", null, h("tr", null, h("th", null, "Setting"), showCurrent ? h("th", null, "On their devices") : null, h("th", null, showCurrent ? "Managed value" : "Default value"), h("th", null, ""))),
      tbody));
    return {
      el,
      changes() {
        const out = {};
        for (const { r, c } of controls) {
          const now = c.read();
          if (JSON.stringify(now) !== JSON.stringify(c.initial)) out[r.spec.key] = now;
        }
        return out;
      },
    };
  }

  // Pickers on the "Add a user" form.
  function newUserPickers(servers, addons) {
    const serverRows = servers.map((s) => {
      const cb = h("input", { type: "checkbox", class: "chk" });
      const mode = h("select", { class: "input", "aria-label": "Sign-in method" }, AUTH_MODES.map((m) => h("option", { value: m.id }, m.label)));
      const uname = h("input", { class: "input", placeholder: "Dispatcharr username", autocomplete: "off", spellcheck: "false" });
      const secret = h("input", { class: "input", type: "password", autocomplete: "new-password" });
      const syncPh = () => { secret.placeholder = mode.value === "xc" ? "XC password" : mode.value === "web" ? "Web password" : "API key"; };
      mode.addEventListener("change", syncPh); syncPh();
      const creds = h("div", { class: "row creds", hidden: true }, h("div", { class: "field" }, mode), h("div", { class: "field" }, uname), h("div", { class: "field" }, secret));
      cb.addEventListener("change", () => { creds.hidden = !cb.checked; });
      const el = h("div", { class: "pick" }, h("label", { class: "inline-check" }, cb, h("b", null, s.name), h("span", { class: "muted mono small" }, s.url)), creds);
      return {
        el,
        value: () => {
          if (!cb.checked) return null;
          const v = { serverId: s.id, authMode: mode.value, username: uname.value.trim() };
          v[mode.value === "xc" ? "xcPassword" : mode.value === "web" ? "webPassword" : "apiKey"] = secret.value;
          return v;
        },
        reset: () => { cb.checked = false; creds.hidden = true; uname.value = ""; secret.value = ""; mode.value = "xc"; syncPh(); },
      };
    });
    const forAll = addons.filter((a) => a.allUsers);
    const addonRows = addons.filter((a) => !a.allUsers).map((a) => {
      const cb = h("input", { type: "checkbox", class: "chk" });
      return { el: h("label", { class: "inline-check pick-addon" }, cb, addonLogo(a.logo), h("b", null, a.name)), value: () => cb.checked ? a.id : null, reset: () => { cb.checked = false; } };
    });
    const el = h("details", { class: "assign-details" },
      h("summary", null, "Assign Dispatcharr and addons right away (optional)"),
      h("div", { class: "assign-grid" },
        h("div", null, h("h4", null, "Dispatcharr"),
          serverRows.length ? serverRows.map((r) => r.el) : h("p", { class: "muted small" }, "No connections yet — add them on the ", h("a", { href: "#/dispatcharr" }, "Dispatcharr"), " page.")),
        h("div", null, h("h4", null, "Addons"),
          addonRows.length ? addonRows.map((r) => r.el) : h("p", { class: "muted small" }, "No addons to pick — manage the library on the ", h("a", { href: "#/addons" }, "Addons"), " page."),
          forAll.length ? h("p", { class: "muted small" }, plural(forAll.length, "addon") + " for all users are added automatically: " + forAll.map((a) => a.name).join(", ") + ".") : null)));
    return {
      el,
      servers: () => serverRows.map((r) => r.value()).filter(Boolean),
      addons: () => addonRows.map((r) => r.value()).filter(Boolean),
      reset: () => { serverRows.forEach((r) => r.reset()); addonRows.forEach((r) => r.reset()); el.open = false; },
    };
  }

  // ---------- Dispatcharr ----------
  function viewDispatcharr() {
    const list = h("div", null, loadingCard());
    const err = h("div", { class: "form-error" });
    const name = h("input", { class: "input", required: true, placeholder: "e.g. Home IPTV", autocomplete: "off" });
    const url = h("input", { class: "input", required: true, placeholder: "http://192.168.1.10:9191", autocomplete: "off", spellcheck: "false", inputmode: "url" });
    const btn = h("button", { class: "btn primary", type: "submit" }, "Add connection");
    const form = h("form", { onsubmit: (e) => { e.preventDefault(); add(); } },
      h("div", { class: "row" },
        h("label", { class: "field" }, h("span", null, "Name"), name),
        h("label", { class: "field" }, h("span", null, "URL"), url), btn), err);
    const add = busy(btn, async () => {
      err.textContent = "";
      try {
        const s = await api("POST", "/api/admin/dispatcharr", { name: name.value.trim(), url: url.value.trim() });
        name.value = url.value = "";
        toast("Added " + s.name + ". Tick the users who should get it.", "ok"); load();
      } catch (e) { err.textContent = e.message; }
    });

    let users = [];
    async function load() {
      try {
        const [s, u] = await Promise.all([api("GET", "/api/admin/dispatcharr"), api("GET", "/api/users")]);
        users = u.users;
        list.replaceChildren(...(s.servers.length ? s.servers.map(serverCard) : [messageCard("No Dispatcharr connections yet. Add one above, then tick the users who should get it.")]));
      } catch (e) { list.replaceChildren(messageCard(e.message)); }
    }

    function serverCard(s) {
      const byUser = Object.fromEntries(s.assignments.map((x) => [x.userId, x]));
      const base = "/api/admin/dispatcharr/" + enc(s.id);
      const rows = users.map((u) => {
        const x = byUser[u.id];
        const cb = h("input", { type: "checkbox", class: "chk", checked: !!x, "aria-label": "Assign " + s.name + " to " + u.username });
        cb.addEventListener("change", async () => {
          if (cb.checked) {
            const body = await credentialsDialog("Assign " + s.name + " to " + u.username, null);
            if (!body) { cb.checked = false; return; }
            try { await api("PUT", base + "/users/" + enc(u.id), body); toast(s.name + " assigned to " + u.username + ".", "ok"); load(); }
            catch (e) { cb.checked = false; toast(e.message, "error"); }
          } else {
            const ok = await confirmDialog("Remove " + s.name + " from " + u.username + "?", "It disappears from all of their devices on the next sync, together with its saved credentials.", "Remove", true);
            if (!ok) { cb.checked = true; return; }
            try { await api("DELETE", base + "/users/" + enc(u.id)); toast(s.name + " removed from " + u.username + ".", "ok"); load(); }
            catch (e) { cb.checked = true; toast(e.message, "error"); }
          }
        });
        const credBtn = x ? h("button", { class: "btn sm", type: "button", onclick: async () => {
          const body = await credentialsDialog(s.name + " · " + u.username, x);
          if (!body) return;
          try { await api("PUT", base + "/users/" + enc(u.id), body); toast("Credentials updated for " + u.username + ".", "ok"); load(); }
          catch (e) { toast(e.message, "error"); }
        } }, "Credentials") : null;
        return h("tr", { class: x ? "on" : null },
          h("td", { class: "chk-cell" }, cb),
          h("td", null, h("a", { class: "user-link", href: "#/user?id=" + enc(u.id) }, u.username), u.disabled ? h("span", { class: "badge danger" }, "Disabled") : null),
          h("td", null, x ? [authLabel(x.authMode), x.username ? h("span", { class: "muted" }, " · " + x.username) : null] : h("span", { class: "muted" }, "—")),
          h("td", null, x ? credBadges(x) : null),
          h("td", { class: "actions" }, x ? providerTestButton(base + "/users/" + enc(u.id) + "/test") : null, credBtn));
      });
      const editBtn = h("button", { class: "btn sm", type: "button", onclick: async () => {
        const v = await formDialog("Edit " + s.name, "Changes reach every assigned user's devices on their next sync.", [
          { key: "name", label: "Name", value: s.name, required: true },
          { key: "url", label: "URL", value: s.url, required: true },
          { key: "order", label: "Order (lower comes first)", value: s.order, type: "number" },
        ]);
        if (!v) return;
        const body = { name: v.name, url: v.url };
        if (v.order != null) body.order = v.order;
        try { await api("PATCH", base, body); toast("Saved.", "ok"); load(); } catch (e) { toast(e.message, "error"); }
      } }, "Edit");
      const delBtn = h("button", { class: "btn sm danger", type: "button", onclick: async () => {
        const ok = await confirmDialog("Delete " + s.name + "?", s.assignments.length ? "It is removed from " + plural(s.assignments.length, "user") + " and their devices, with its credentials." : "Nobody is using it.", "Delete", true);
        if (!ok) return;
        try { await api("DELETE", base); toast(s.name + " deleted.", "ok"); load(); } catch (e) { toast(e.message, "error"); }
      } }, "Delete");
      return h("div", { class: "card" },
        h("div", { class: "card-head" },
          h("div", { class: "card-title" }, h("div", { class: "device-icon" }, icon("dispatcharr")),
            h("div", null, h("h2", null, s.name), h("div", { class: "mono muted small" }, s.url), h("div", { class: "muted small" }, plural(s.assignments.length, "user") + " · id " + s.id))),
          h("div", { class: "btns" }, editBtn, delBtn)),
        h("div", { class: "table-wrap" }, h("table", { class: "assign-table" },
          h("thead", null, h("tr", null, h("th", null, ""), h("th", null, "User"), h("th", null, "Account"), h("th", null, "Credentials"), h("th", null, ""))),
          h("tbody", null, rows))));
    }

    load();
    return h("div", null,
      pageHead("Dispatcharr", "Connections you manage for your users. Each assigned user gets the server (and, on devices with the Secrets scope, their own credentials) and can't remove it."),
      h("div", { class: "card" }, h("h2", null, "Add a connection"), h("p", { class: "sub" }, "The URL your users' devices use to reach Dispatcharr."), form),
      list);
  }

  // ---------- Addons ----------
  function viewAddons() {
    const matrix = h("div", null, loadingCard());
    const err = h("div", { class: "form-error" });
    const url = h("input", { class: "input", required: true, placeholder: "https://…/manifest.json or stremio://…", autocomplete: "off", spellcheck: "false", inputmode: "url" });
    const name = h("input", { class: "input", placeholder: "from the manifest", autocomplete: "off" });
    const all = h("input", { type: "checkbox", class: "chk" });
    const btn = h("button", { class: "btn primary", type: "submit" }, "Add addon");
    const form = h("form", { onsubmit: (e) => { e.preventDefault(); add(); } },
      h("div", { class: "row" },
        h("label", { class: "field grow2" }, h("span", null, "Manifest URL"), url),
        h("label", { class: "field" }, h("span", null, "Name (optional)"), name),
        btn),
      h("label", { class: "inline-check" }, all, "Give it to all users (including users created later)"), err);
    const add = busy(btn, async () => {
      err.textContent = "";
      try {
        const v = await api("POST", "/api/admin/addons", { url: url.value.trim(), name: name.value.trim(), allUsers: all.checked });
        url.value = name.value = ""; all.checked = false;
        toast(v.fetchError ? "Added " + v.name + " (manifest: " + v.fetchError + ")." : "Added " + v.name + ".", v.fetchError ? "" : "ok");
        load();
      } catch (e) { err.textContent = e.message; }
    });

    async function load() {
      try {
        const [lib, u] = await Promise.all([api("GET", "/api/admin/addons"), api("GET", "/api/users")]);
        matrix.replaceChildren(lib.addons.length ? table(lib.addons, u.users) : messageCard("The library is empty. Add an addon above, then tick who gets it."));
      } catch (e) { matrix.replaceChildren(messageCard(e.message)); }
    }

    function table(addons, users) {
      const head = h("tr", null, h("th", null, "Addon"), h("th", { class: "center" }, "All users"),
        users.map((u) => h("th", { class: "center user-col" }, h("a", { class: "user-link", href: "#/user?id=" + enc(u.id) }, u.username))),
        h("th", null, ""));
      const rows = addons.map((v) => {
        const base = "/api/admin/addons/" + enc(v.id);
        const assigned = new Set(v.users.map((x) => x.id));
        const allCb = h("input", { type: "checkbox", class: "chk", checked: v.allUsers, "aria-label": v.name + " for all users" });
        allCb.addEventListener("change", async () => {
          const on = allCb.checked;
          if (!on) {
            const ok = await confirmDialog("Stop giving " + v.name + " to everyone?", "Users without a direct tick lose it on their next sync.", "Continue", true);
            if (!ok) { allCb.checked = true; return; }
          }
          try { await api("PATCH", base, { allUsers: on }); toast(v.name + (on ? " now goes to all users." : " is no longer for all users."), "ok"); load(); }
          catch (e) { allCb.checked = !on; toast(e.message, "error"); }
        });
        const cells = users.map((u) => {
          const cb = h("input", { type: "checkbox", class: "chk", checked: v.allUsers || assigned.has(u.id), disabled: v.allUsers, title: v.allUsers ? "Assigned to all users" : null, "aria-label": v.name + " for " + u.username });
          cb.addEventListener("change", async () => {
            try {
              await api(cb.checked ? "PUT" : "DELETE", base + "/users/" + enc(u.id));
              toast(v.name + (cb.checked ? " assigned to " : " removed from ") + u.username + ".", "ok");
            } catch (e) { cb.checked = !cb.checked; toast(e.message, "error"); }
          });
          return h("td", { class: "center" }, cb);
        });
        const refresh = h("button", { class: "btn sm", type: "button", title: "Test the connection and refresh the manifest" }, "Test & refresh");
        refresh.addEventListener("click", busy(refresh, async () => {
          try { const r = await api("POST", base + "/refresh"); toast(r.fetchError ? "Manifest: " + r.fetchError : "Manifest updated.", r.fetchError ? "error" : "ok"); load(); }
          catch (e) { toast(e.message, "error"); }
        }));
        const edit = h("button", { class: "btn sm", type: "button", onclick: async () => {
          const r = await formDialog("Edit " + v.name, "Leave the name empty to use the manifest's name.", [
            { key: "name", label: "Name", value: v.customName, placeholder: v.manifestName || "" },
            { key: "order", label: "Order (lower comes first)", value: v.order, type: "number" },
          ]);
          if (!r) return;
          const body = { name: r.name };
          if (r.order != null) body.order = r.order;
          try { await api("PATCH", base, body); toast("Saved.", "ok"); load(); } catch (e) { toast(e.message, "error"); }
        } }, "Edit");
        const del = h("button", { class: "btn sm danger", type: "button", onclick: async () => {
          const ok = await confirmDialog("Delete " + v.name + "?", "It is removed from the library and from every user it was assigned to.", "Delete", true);
          if (!ok) return;
          try { await api("DELETE", base); toast(v.name + " deleted.", "ok"); load(); } catch (e) { toast(e.message, "error"); }
        } }, "Delete");
        return h("tr", null,
          h("td", null, h("div", { class: "addon-cell" }, addonLogo(v.logo),
            h("div", { class: "addon-info" },
              h("div", null, h("b", null, v.name), v.version ? h("span", { class: "muted small" }, " v" + v.version) : null),
              v.description ? h("div", { class: "muted small clamp" }, v.description) : null,
              h("div", { class: "mono muted small url", title: v.transportUrl }, v.transportUrl),
              v.fetchError ? h("div", { class: "badge warn", title: v.fetchError }, "Manifest: " + v.fetchError) : null))),
          h("td", { class: "center" }, allCb),
          cells,
          h("td", { class: "actions" }, refresh, edit, del));
      });
      return h("div", { class: "card" },
        h("h2", null, "Who gets what"), h("p", { class: "sub" }, "Ticked users get the addon installed on all their devices and can't remove it. Unticking removes it from their devices."),
        h("div", { class: "table-wrap" }, h("table", { class: "matrix" }, h("thead", null, head), h("tbody", null, rows))));
    }

    load();
    return h("div", null,
      pageHead("Addons", "An addon library you manage. Devices fetch each manifest themselves; the server only checks it to show its name and logo."),
      h("div", { class: "card" }, h("h2", null, "Add an addon"), h("p", { class: "sub" }, "Paste the (configured) manifest link. stremio:// links work too."), form),
      matrix);
  }

  // ---------- Default settings ----------
  function viewDefaults() {
    const body = h("div", null, loadingCard());
    async function load() {
      try {
        const r = await api("GET", "/api/admin/settings");
        const editor = settingsEditor(r.keys.map((k) => ({ spec: k, managedValue: k.key in r.defaults ? r.defaults[k.key] : null })), false);
        const save = h("button", { class: "btn primary", type: "button" }, "Save defaults");
        save.addEventListener("click", busy(save, async () => {
          const values = editor.changes();
          if (!Object.keys(values).length) { toast("Nothing changed."); return; }
          try { await api("PUT", "/api/admin/settings/defaults", { values }); toast("Defaults saved. New users get them automatically.", "ok"); load(); }
          catch (e) { toast(e.message, "error"); }
        }));
        const push = h("button", { class: "btn", type: "button" }, "Push to all existing users");
        push.addEventListener("click", busy(push, async () => {
          if (Object.keys(editor.changes()).length) { toast("Save your changes first.", "error"); return; }
          const ok = await confirmDialog("Push defaults to everyone?", "Every existing user gets these values as managed (locked) settings, replacing their own values for these keys.", "Push to all users");
          if (!ok) return;
          try { const res = await api("POST", "/api/admin/settings/defaults/apply"); toast("Pushed to " + plural(res.users, "user") + ".", "ok"); }
          catch (e) { toast(e.message, "error"); }
        }));
        body.replaceChildren(h("div", { class: "card" },
          h("h2", null, "Defaults for all users"),
          h("p", { class: "sub" }, "Values set here are applied as managed settings to every user created from now on. Leave a setting at “— not set” to let users choose. Per-user overrides live on each user's page."),
          editor.el,
          h("div", { class: "btns end" }, push, save)));
      } catch (e) { body.replaceChildren(messageCard(e.message)); }
    }
    load();
    return h("div", null, pageHead("Default settings", "Synced app settings you set for everyone."), body);
  }

  // ---------- User detail ----------
  function viewUser() {
    const id = qparam("id");
    const root = h("div", null, pageHead("User", null), loadingCard());
    if (!id) { root.replaceChildren(pageHead("User", null), messageCard("No user selected.")); return root; }
    const userBase = "/api/admin/users/" + enc(id);

    async function load() {
      try {
        const [d, conns, all] = await Promise.all([api("GET", userBase), api("GET", "/api/admin/dispatcharr"), api("GET", "/api/users")]);
        draw(d, conns.servers, all.users);
      } catch (e) { root.replaceChildren(pageHead("User", null), messageCard(e.message)); }
    }

    function draw(d, conns, allUsers) {
      const u = d.user;
      const copyBtn = h("button", { class: "btn", type: "button", onclick: () => copyFrom(u, allUsers) }, "Copy from user…");
      const head = pageHead(u.username,
        (u.role === "admin" ? "Administrator" : "Member") + " · created " + fullDate(u.createdAt),
        h("div", { class: "toolbar" }, h("a", { class: "btn ghost", href: "#/users" }, "← Users"), copyBtn));
      const s = d.stats;
      const stats = h("div", { class: "stats" },
        stat("Records", num(s.records), "across " + s.collections.length + " collections"),
        stat("Devices", num(d.devices.length), d.devices.length ? "latest: " + d.devices.slice().sort((a, b) => b.lastSeenAt - a.lastSeenAt)[0].name : "none yet"),
        stat("Last sync", s.lastSyncAt ? ago(s.lastSyncAt) : "never", s.lastSyncAt ? fullDate(s.lastSyncAt) : ""),
        stat("Revision", num(s.rev), "server change counter"));
      const notes = [];
      if (u.disabled) notes.push(h("div", { class: "card warn-card" }, "This account is disabled. Assignments are kept and apply again when it is re-enabled."));
      if (u.role === "admin") notes.push(h("div", { class: "card note-card" }, "Administrators' own devices may change managed records of their account; members' devices can't."));
      root.replaceChildren(...[head, ...notes, stats,
        devicesCard(d), dispatcharrCard(d, conns), addonsCard(d), settingsCard(d), dismissedCard(d), countsCard(d)].filter(Boolean));
    }

    function dismissedCard(d) {
      const list = d.dismissed || [];
      if (!list.length) return null;
      const kinds = { servers: "Dispatcharr", addons: "Addon", settings: "Setting" };
      const rows = list.map((x) => {
        const btn = h("button", { class: "btn sm", type: "button" }, "Push again");
        btn.addEventListener("click", busy(btn, async () => {
          const ok = await confirmDialog("Push " + x.name + " again?", "It comes back on " + d.user.username + "'s devices on their next sync. They can remove it again.", "Push again", false);
          if (!ok) return;
          try { await api("POST", userBase + "/dismissed/restore", { collection: x.collection, id: x.id }); toast(x.name + " pushed again.", "ok"); load(); }
          catch (e) { toast(e.message, "error"); }
        }));
        return h("tr", null,
          h("td", null, h("b", null, x.name), x.collection !== "settings" ? h("div", { class: "mono muted small url", title: x.id }, x.id) : null),
          h("td", null, h("span", { class: "badge" }, kinds[x.collection] || x.collection)),
          h("td", { class: "muted" }, timeEl(x.dismissedAt)),
          h("td", { class: "actions" }, btn));
      });
      return h("div", { class: "card" },
        h("h2", null, "Removed by user"),
        h("p", { class: "sub" }, "Managed items " + d.user.username + " chose to continue without. They stay assigned but aren't sent to their devices until you push them again or they restore them in the app."),
        h("div", { class: "table-wrap" }, h("table", null, h("thead", null, h("tr", null, h("th", null, "Item"), h("th", null, "Kind"), h("th", null, "Removed"), h("th", null, ""))), h("tbody", null, rows))));
    }

    function devicesCard(d) {
      const rows = d.devices.sort((a, b) => b.lastSeenAt - a.lastSeenAt).map((x) => h("tr", null,
        h("td", null, h("div", { class: "mini-dev" }, h("span", { class: "mini-icon" }, icon(x.platform)), h("b", null, x.name))),
        h("td", { class: "muted" }, PLATFORM_NAMES[x.platform] || x.platform),
        h("td", null, h("span", { class: "scope-list" }, x.scopes.map((sc) => h("span", { class: "badge" + (sc === "secrets" ? " accent-soft" : "") }, sc)))),
        h("td", { class: "muted" }, timeEl(x.lastSeenAt))));
      return h("div", { class: "card" },
        h("div", { class: "card-head" }, h("div", null, h("h2", null, "Devices"), h("p", { class: "sub" }, "Signed-in apps and browsers. Only devices with the Secrets scope receive Dispatcharr credentials.")),
          h("a", { class: "btn sm", href: "#/devices?user=" + enc(id) }, "Manage devices")),
        rows.length ? h("div", { class: "table-wrap" }, h("table", null, h("thead", null, h("tr", null, h("th", null, "Device"), h("th", null, "Platform"), h("th", null, "Scopes"), h("th", null, "Active"))), h("tbody", null, rows)))
          : h("div", { class: "empty" }, "No devices yet."));
    }

    function dispatcharrCard(d, conns) {
      const assigned = new Set(d.dispatcharr.map((x) => x.serverId));
      const rows = d.dispatcharr.map((x) => {
        const base = "/api/admin/dispatcharr/" + enc(x.serverId) + "/users/" + enc(id);
        return h("tr", null,
          h("td", null, h("b", null, x.serverName), h("div", { class: "mono muted small" }, x.serverUrl)),
          h("td", null, authLabel(x.authMode), x.username ? h("span", { class: "muted" }, " · " + x.username) : null),
          h("td", null, credBadges(x)),
          h("td", { class: "actions" },
            h("button", { class: "btn sm", type: "button", onclick: async () => {
              const body = await credentialsDialog(x.serverName + " · " + d.user.username, x);
              if (!body) return;
              try { await api("PUT", base, body); toast("Credentials updated.", "ok"); load(); } catch (e) { toast(e.message, "error"); }
            } }, "Credentials"),
            h("button", { class: "btn sm danger", type: "button", onclick: async () => {
              const ok = await confirmDialog("Remove " + x.serverName + "?", "It disappears from " + d.user.username + "'s devices on their next sync, with its credentials.", "Remove", true);
              if (!ok) return;
              try { await api("DELETE", base); toast("Removed.", "ok"); load(); } catch (e) { toast(e.message, "error"); }
            } }, "Unassign")));
      });
      const avail = conns.filter((c) => !assigned.has(c.id));
      const sel = h("select", { class: "input", "aria-label": "Connection to assign" }, avail.map((c) => h("option", { value: c.id }, c.name)));
      const assignBtn = h("button", { class: "btn primary sm", type: "button", disabled: !avail.length, onclick: async () => {
        const c = avail.find((x) => x.id === sel.value);
        if (!c) return;
        const body = await credentialsDialog("Assign " + c.name + " to " + d.user.username, null);
        if (!body) return;
        try { await api("PUT", "/api/admin/dispatcharr/" + enc(c.id) + "/users/" + enc(id), body); toast(c.name + " assigned.", "ok"); load(); }
        catch (e) { toast(e.message, "error"); }
      } }, "Assign");
      const own = d.servers.filter((x) => !x.managed);
      return h("div", { class: "card" },
        h("div", { class: "card-head" }, h("div", null, h("h2", null, "Dispatcharr"), h("p", { class: "sub" }, "Managed connections with this user's own credentials.")),
          avail.length ? h("div", { class: "inline-assign" }, sel, assignBtn) : h("a", { class: "btn sm ghost", href: "#/dispatcharr" }, conns.length ? "All connections assigned" : "Add a connection")),
        rows.length ? h("div", { class: "table-wrap" }, h("table", null, h("thead", null, h("tr", null, h("th", null, "Connection"), h("th", null, "Account"), h("th", null, "Credentials"), h("th", null, ""))), h("tbody", null, rows)))
          : h("div", { class: "empty" }, "No managed Dispatcharr connections."),
        own.length ? h("div", { class: "subsection" }, h("h3", null, "Their own servers"), h("p", { class: "sub" }, "Added on their devices; synced but not managed."),
          h("ul", { class: "plain-list" }, own.map((x) => h("li", null, h("b", null, x.name || "Dispatcharr"), h("span", { class: "mono muted small" }, " " + x.url), x.authMode ? h("span", { class: "muted small" }, " · " + authLabel(x.authMode) + (x.username ? " · " + x.username : "")) : null)))) : null);
    }

    function addonsCard(d) {
      const rows = d.addons.map((x) => {
        const label = x.source === "all" ? managedBadge("All users") : x.managed ? managedBadge("Assigned") : h("span", { class: "badge" }, "Their own");
        const unassign = x.managed && x.source === "direct" && x.libraryId ? h("button", { class: "btn sm danger", type: "button", onclick: async () => {
          const ok = await confirmDialog("Remove " + x.name + "?", "It is uninstalled from " + d.user.username + "'s devices on their next sync.", "Remove", true);
          if (!ok) return;
          try { await api("DELETE", "/api/admin/addons/" + enc(x.libraryId) + "/users/" + enc(id)); toast("Removed.", "ok"); load(); } catch (e) { toast(e.message, "error"); }
        } }, "Unassign") : x.source === "all" ? h("a", { class: "btn sm ghost", href: "#/addons", title: "Assigned to all users — change it on the Addons page" }, "Addons page") : null;
        return h("tr", null,
          h("td", null, h("div", { class: "addon-cell" }, addonLogo(x.logo), h("div", { class: "addon-info" },
            h("b", null, x.name || "Addon"), h("div", { class: "mono muted small url", title: x.transportUrl }, x.transportUrl)))),
          h("td", null, x.enabled ? h("span", { class: "badge ok" }, "Enabled") : h("span", { class: "badge" }, "Disabled")),
          h("td", null, label),
          h("td", { class: "actions" }, unassign));
      });
      const avail = d.libraryAddons.filter((a) => !a.allUsers && !a.assigned);
      const sel = h("select", { class: "input", "aria-label": "Addon to assign" }, avail.map((a) => h("option", { value: a.id }, a.name)));
      const assignBtn = h("button", { class: "btn primary sm", type: "button" }, "Assign");
      assignBtn.addEventListener("click", busy(assignBtn, async () => {
        if (!sel.value) return;
        try { await api("PUT", "/api/admin/addons/" + enc(sel.value) + "/users/" + enc(id)); toast("Addon assigned.", "ok"); load(); } catch (e) { toast(e.message, "error"); }
      }));
      return h("div", { class: "card" },
        h("div", { class: "card-head" }, h("div", null, h("h2", null, "Addons"), h("p", { class: "sub" }, "Everything installed for this user — managed by you, or added on their devices.")),
          avail.length ? h("div", { class: "inline-assign" }, sel, assignBtn) : h("a", { class: "btn sm ghost", href: "#/addons" }, "Addon library")),
        rows.length ? h("div", { class: "table-wrap" }, h("table", null, h("thead", null, h("tr", null, h("th", null, "Addon"), h("th", null, "State"), h("th", null, "Source"), h("th", null, ""))), h("tbody", null, rows)))
          : h("div", { class: "empty" }, "No addons synced yet."));
    }

    function settingsCard(d) {
      const editor = settingsEditor(d.settings.map((x) => ({ spec: x, current: x.value, managedValue: x.managed ? x.managedValue : null })), true);
      const save = h("button", { class: "btn primary", type: "button" }, "Save managed settings");
      save.addEventListener("click", busy(save, async () => {
        const values = editor.changes();
        if (!Object.keys(values).length) { toast("Nothing changed."); return; }
        try { await api("PUT", userBase + "/settings", { values }); toast("Settings saved. Their devices pick them up on the next sync.", "ok"); load(); }
        catch (e) { toast(e.message, "error"); }
      }));
      return h("div", { class: "card" },
        h("h2", null, "Settings"),
        h("p", { class: "sub" }, "A managed value is pushed to all of this user's devices and locked there. Set it back to “— not set” to release it (the value stays, but they can change it again)."),
        editor.el, h("div", { class: "btns end" }, save));
    }

    function countsCard(d) {
      const cs = d.stats.collections;
      const max = Math.max(1, ...cs.map((c) => c.count + c.deleted));
      return h("div", { class: "card" }, h("h2", null, "Records"), h("p", { class: "sub" }, "Synced records per collection."),
        cs.length ? h("div", { class: "bars" }, cs.map((c) => {
          const fill = h("div", { class: "bar-fill" });
          fill.style.width = Math.max(1, (c.count / max) * 100) + "%";
          return h("div", { class: "bar-row" }, h("div", { class: "name", title: c.collection }, c.collection), h("div", { class: "bar-track" }, fill),
            h("div", { class: "num" }, num(c.count), c.deleted ? h("small", null, num(c.deleted) + " deleted") : null));
        })) : h("div", { class: "empty" }, "Nothing synced yet."));
    }

    async function copyFrom(target, allUsers) {
      const others = allUsers.filter((x) => x.id !== target.id);
      if (!others.length) { toast("There's no other user to copy from.", "error"); return; }
      const res = await showDialog((close) => {
        const sel = h("select", { class: "input" }, others.map((x) => h("option", { value: x.id }, x.username)));
        const boxes = [["addons", "Addons"], ["servers", "Dispatcharr servers (with their credentials)"], ["settings", "Settings"]].map(([k, l]) => {
          const cb = h("input", { type: "checkbox", class: "chk", checked: true });
          return { k, cb, el: h("label", { class: "inline-check" }, cb, l) };
        });
        return h("form", { class: "dlg", onsubmit: (e) => {
          e.preventDefault();
          const body = { from: sel.value };
          for (const b of boxes) body[b.k] = b.cb.checked;
          close(body);
        } },
          h("h3", null, "Copy configuration to " + target.username),
          h("p", null, "Takes the other user's current addons, Dispatcharr servers and settings and assigns the same to " + target.username + " as managed configuration. Dispatcharr accounts are usually per person — review the credentials afterwards."),
          h("label", { class: "field" }, h("span", null, "Copy from"), sel),
          h("div", { class: "field" }, boxes.map((b) => b.el)),
          h("div", { class: "btns" },
            h("button", { type: "button", class: "btn ghost", onclick: () => close(undefined) }, "Cancel"),
            h("button", { type: "submit", class: "btn primary" }, "Copy")));
      });
      if (!res) return;
      try {
        const c = await api("POST", userBase + "/copy", res);
        toast("Copied " + plural(c.addons, "addon") + ", " + plural(c.servers, "server") + " and " + plural(c.settings, "setting") + ".", "ok");
        load();
      } catch (e) { toast(e.message, "error"); }
    }

    load();
    return root;
  }

  // ---------- Activity ----------
  function viewActivity() {
    const isAdmin = state.me.user.role === "admin";
    const tbody = h("tbody", null, h("tr", null, h("td", { colspan: 5, class: "empty" }, "Loading…")));
    const more = h("button", { class: "btn sm", type: "button", hidden: true }, "Load older");
    let before = 0;
    let first = true;
    async function load() {
      try {
        const r = await api("GET", "/api/audit?limit=100" + (before ? "&before=" + before : ""));
        if (first) { tbody.replaceChildren(); first = false; }
        for (const e of r.events) tbody.append(row(e));
        if (!tbody.children.length) tbody.append(h("tr", null, h("td", { colspan: 5, class: "empty" }, "No activity yet.")));
        if (r.events.length) before = r.events[r.events.length - 1].id;
        more.hidden = r.events.length < 100;
      } catch (e) { tbody.replaceChildren(h("tr", null, h("td", { colspan: 5, class: "empty" }, e.message))); }
    }
    more.addEventListener("click", busy(more, load));
    function evClass(ev) {
      if (/failed/.test(ev)) return "bad";
      if (/^(device\.revoke|user\.(disable|delete)|logout)/.test(ev)) return "warn";
      if (/^pair/.test(ev)) return "pair";
      if (/^admin\./.test(ev)) return "admin";
      if (/^(login|signup|setup)/.test(ev)) return ev.split(".")[0];
      return "";
    }
    function row(e) {
      return h("tr", null,
        h("td", { class: "muted" }, timeEl(e.ts)),
        h("td", null, e.username || "—"),
        h("td", null, h("span", { class: "ev " + evClass(e.event) }, e.event)),
        h("td", null, e.detail),
        h("td", { class: "mono muted" }, e.ip));
    }
    load();
    return h("div", null,
      pageHead("Activity", isAdmin ? "Sign-ins, pairings, revocations and account changes on this server." : "Sign-ins, pairings and changes on your account."),
      h("div", { class: "card" }, h("div", { class: "table-wrap" },
        h("table", null, h("thead", null, h("tr", null, h("th", null, "When"), h("th", null, "User"), h("th", null, "Event"), h("th", null, "Details"), h("th", null, "IP"))), tbody))),
      more);
  }

  // ---------- Account ----------
  function viewAccount() {
    const me = state.me;
    const err = h("div", { class: "form-error" });
    const cur = h("input", { class: "input", type: "password", autocomplete: "current-password", required: true });
    const n1 = h("input", { class: "input", type: "password", autocomplete: "new-password", minlength: 8, required: true });
    const n2 = h("input", { class: "input", type: "password", autocomplete: "new-password", minlength: 8, required: true });
    const btn = h("button", { class: "btn primary", type: "submit" }, "Change password");
    const form = h("form", { onsubmit: (e) => { e.preventDefault(); submit(); } },
      h("label", { class: "field" }, h("span", null, "Current password"), cur),
      h("div", { class: "row" },
        h("label", { class: "field" }, h("span", null, "New password"), n1),
        h("label", { class: "field" }, h("span", null, "Repeat new password"), n2)),
      err, btn);
    const submit = busy(btn, async () => {
      err.textContent = "";
      if (n1.value !== n2.value) { err.textContent = "New passwords don't match."; return; }
      try {
        await api("POST", "/api/me/password", { current: cur.value, new: n1.value });
        cur.value = n1.value = n2.value = "";
        toast("Password changed.", "ok");
      } catch (e) { err.textContent = e.message; }
    });
    const origin = location.origin;
    return h("div", null,
      pageHead("Account", null),
      h("div", { class: "card" },
        h("h2", null, "Profile"), h("p", { class: "sub" }, "Your account on this server."),
        h("dl", { class: "kv" },
          h("dt", null, "Username"), h("dd", null, me.user.username),
          h("dt", null, "Role"), h("dd", null, me.user.role === "admin" ? "Administrator" : "Member"),
          h("dt", null, "Member since"), h("dd", null, fullDate(me.user.createdAt)),
          h("dt", null, "Server"), h("dd", null, me.server.name + " · v" + me.server.version),
          h("dt", null, "Server URL"), h("dd", { class: "mono" }, origin))),
      h("div", { class: "card" },
        h("h2", null, "Connect the app"),
        h("p", { class: "sub" }, "In StreamForge’s sync settings on iPhone, iPad or Android, enter the server URL above, then your username and password. On a TV, choose to pair with a code and approve it on the Pair a TV page.")),
      h("div", { class: "card" }, h("h2", null, "Change password"), h("p", { class: "sub" }, "Devices that are already signed in stay signed in."), form));
  }

  // ---------- render ----------
  function render() {
    if (state.setup && state.setup.needsSetup) { $app.replaceChildren(viewSetup()); document.title = "Set up · StreamForge Sync"; return; }
    if (!state.token || !state.me) { $app.replaceChildren(viewSignIn()); document.title = "Sign in · StreamForge Sync"; return; }
    const route = currentRoute();
    $app.replaceChildren(shell(route, route.view()));
    document.title = route.label + " · " + state.me.server.name;
    const auto = $app.querySelector("[autofocus]");
    if (auto) auto.focus();
  }

  window.addEventListener("hashchange", () => { if (state.me) render(); });

  async function boot() {
    try {
      state.setup = await api("GET", "/api/setup");
    } catch (e) {
      $app.replaceChildren(h("div", { class: "auth" }, h("div", { class: "auth-card" }, h("h1", null, "Can't reach the server"), h("p", { class: "lead" }, e.message))));
      return;
    }
    if (!state.setup.needsSetup && state.token) {
      try { state.me = await api("GET", "/api/me"); }
      catch { state.token = null; sessionSet(TOKEN_KEY, null); }
    }
    render();
  }
  boot();
})();
