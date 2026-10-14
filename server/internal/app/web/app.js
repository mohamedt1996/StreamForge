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
    overview: "M3 13h8V3H3zM13 21h8V11h-8zM3 21h8v-6H3zM13 3v6h8V3z",
    devices: "M4 5h16v10H4zM2 19h20M9 15v4M15 15v4",
    pair: "M3 6h18v11H3zM8 21h8M12 17v4M9 10.5h6",
    users: "M16 19v-1a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v1M9 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM22 19v-1a4 4 0 0 0-3-3.9M16 3.1a3.5 3.5 0 0 1 0 6.8",
    activity: "M22 12h-4l-3 8L9 4l-3 8H2",
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
    { id: "devices", label: "Devices", view: viewDevices },
    { id: "pair", label: "Pair a TV", view: viewPair },
    { id: "users", label: "Users", view: viewUsers, admin: true },
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
          ROUTES.filter((r) => !r.admin || isAdmin).map((r) =>
            h("a", { href: "#/" + r.id, class: r.id === route.id ? "active" : null, "aria-current": r.id === route.id ? "page" : null }, icon(r.id), r.label))),
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
            h("span", null, "active ", timeEl(d.lastSeenAt)),
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
    const form = h("form", { onsubmit: (e) => { e.preventDefault(); create(); } },
      h("div", { class: "row" },
        h("label", { class: "field" }, h("span", null, "Username"), u),
        h("label", { class: "field" }, h("span", null, "Password"), p),
        h("label", { class: "field" }, h("span", null, "Role"), role),
        btn), err);
    const create = busy(btn, async () => {
      err.textContent = "";
      try {
        const nu = await api("POST", "/api/users", { username: u.value.trim(), password: p.value, role: role.value });
        u.value = ""; p.value = ""; role.value = "member";
        toast("Created " + nu.username + ".", "ok"); load();
      } catch (e) { err.textContent = e.message; }
    });

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
        h("td", null, h("b", null, user.username), self ? h("span", { class: "badge accent" }, " you") : null),
        h("td", null, roleSel),
        h("td", null, user.disabled ? h("span", { class: "badge danger" }, "Disabled") : h("span", { class: "badge ok" }, "Active")),
        h("td", { class: "muted" }, timeEl(user.createdAt)),
        h("td", { class: "actions" },
          h("a", { class: "btn sm ghost", href: "#/devices?user=" + encodeURIComponent(user.id) }, "Devices"),
          resetBtn, disBtn, delBtn));
    }
    load();
    return h("div", null,
      pageHead("Users", "Each user has their own completely separate library, progress and settings."),
      h("div", { class: "card" }, h("h2", null, "Add a user"), h("p", { class: "sub" }, "They sign in from the app with this username and password."), form),
      h("div", { class: "card" }, h("div", { class: "table-wrap" },
        h("table", null, h("thead", null, h("tr", null, h("th", null, "User"), h("th", null, "Role"), h("th", null, "Status"), h("th", null, "Created"), h("th", null, ""))), tbody))));
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
