#!/usr/bin/osascript -l JavaScript

function run(argv) {
  const options = parseOptions(argv);
  const targetUrl = options.url || "https://klms.kaist.ac.kr/my/";
  const displayName = options["display-name"] || "";
  const maxSeconds = Math.max(0, Number(options["max-seconds"] || "0"));
  const pollMs = Math.max(75, Math.min(1000, Number(options["poll-ms"] || "150")));
  if (!displayName) {
    return JSON.stringify({ status: "error", error: "missing-display-name" });
  }

  const safari = Application("/Applications/Safari.app");
  if (!safeBoolean(() => safari.running())) {
    safari.launch();
  }

  const windowRef = resolveWindow(safari);
  if (!windowRef) {
    return JSON.stringify({ status: "error", error: "no-safari-window" });
  }

  const tab = resolveTab(windowRef);
  if (!tab) {
    return JSON.stringify({ status: "error", error: "no-safari-tab" });
  }

  if (maxSeconds > 0) {
    return JSON.stringify(advanceUntilTerminal(tab, targetUrl, displayName, maxSeconds, pollMs));
  }
  return JSON.stringify(advanceOneStep(tab, targetUrl, displayName));
}

function advanceUntilTerminal(tab, targetUrl, displayName, maxSeconds, pollMs) {
  const deadline = Date.now() + maxSeconds * 1000;
  let lastPayload = { status: "waiting" };

  while (Date.now() < deadline) {
    const payload = advanceOneStep(tab, targetUrl, displayName);
    lastPayload = payload;
    if (isTerminalStatus(payload.status)) {
      return payload;
    }
    delay(pollMs / 1000);
  }

  lastPayload.timeout = true;
  return lastPayload;
}

function isTerminalStatus(status) {
  return status === "authenticated" || status === "twofactor_digits" || status === "error";
}

function advanceOneStep(tab, targetUrl, displayName) {
  let url = safeString(() => tab.url());
  if (!looksLikeKaistAuthUrl(url)) {
    tab.url = targetUrl;
    url = safeString(() => tab.url());
    return { status: "navigated", url };
  }

  const urlLower = url.toLowerCase();

  if (
    urlLower.includes("klms.kaist.ac.kr") &&
    !urlLower.includes("/login/") &&
    !urlLower.includes("ssologin.php")
  ) {
    return { status: "authenticated", url, title: readTitle(tab) };
  }

  if (urlLower.includes("klms.kaist.ac.kr/login/ssologin.php")) {
    const result = runPageScript(tab, `
(() => {
  const link = document.querySelector("div.login > a");
  if (!link) return JSON.stringify({ ok: false, reason: "missing-link" });
  if (document.body && document.body.dataset.klmsLoginAssistSsoClicked === "1") {
    return JSON.stringify({ ok: false, reason: "sso-click-already-submitted" });
  }
  if (document.body) document.body.dataset.klmsLoginAssistSsoClicked = "1";
  link.click();
  return JSON.stringify({ ok: true });
})();
`);
    const payload = parseJson(result);
    return {
      status: payload.ok ? "klms_redirect_clicked" : "waiting",
      reason: payload.reason || "",
      url
    };
  }

  if (urlLower.includes("sso.kaist.ac.kr/auth/kaist/user/login/view")) {
    const result = runPageScript(tab, `
(() => {
  const displayName = ${JSON.stringify(displayName)};
  const input = document.querySelector("#login_id_mfa");
  if (!input) return JSON.stringify({ ok: false, reason: "missing-input" });
  if (document.body && document.body.dataset.klmsLoginAssistMfaSubmitted === "1") {
    return JSON.stringify({ ok: false, reason: "login-already-submitted" });
  }
  const proto = Object.getPrototypeOf(input);
  const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
  if (setter) setter.call(input, displayName);
  else input.value = displayName;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  if (document.body) document.body.dataset.klmsLoginAssistMfaSubmitted = "1";
  if (typeof window.loginProcMfa === "function") {
    window.loginProcMfa();
    return JSON.stringify({ ok: true, method: "loginProcMfa" });
  }
  const button = document.querySelector("a.btn_login");
  if (button) {
    button.click();
    return JSON.stringify({ ok: true, method: "button" });
  }
  return JSON.stringify({ ok: false, reason: "missing-login-action" });
})();
`);
    const payload = parseJson(result);
    return {
      status: payload.ok ? "login_submitted" : "waiting",
      reason: payload.reason || "",
      method: payload.method || "",
      url
    };
  }

  if (urlLower.includes("sso.kaist.ac.kr/auth/twofactor/mfa/login2factor")) {
    const result = runPageScript(tab, `
(() => {
  const wrap = document.querySelector(".auth_number .nember_wrap");
  if (wrap) {
    const spans = wrap.querySelectorAll("span");
    if (spans.length >= 2) {
      const a = (spans[0].textContent || "").trim();
      const b = (spans[1].textContent || "").trim();
      if (/^\\d$/.test(a) && /^\\d$/.test(b)) {
        return JSON.stringify({ ok: true, digits: a + b });
      }
    }
  }
  const sr = document.querySelector(".auth_number .sr-only");
  if (sr) {
    const text = (sr.textContent || "").trim();
    if (/^\\d{2}$/.test(text)) return JSON.stringify({ ok: true, digits: text });
  }
  return JSON.stringify({ ok: false, reason: "digits-not-ready" });
})();
`);
    const payload = parseJson(result);
    return {
      status: payload.ok ? "twofactor_digits" : "waiting",
      digits: payload.digits || "",
      reason: payload.reason || "",
      url
    };
  }

  return { status: "waiting", url };
}

function readTitle(tab) {
  return safeString(() => tab.name());
}

function parseOptions(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = String(argv[i]);
    if (!arg.startsWith("--")) continue;
    const eq = arg.indexOf("=");
    if (eq >= 0) {
      options[arg.slice(2, eq)] = arg.slice(eq + 1);
    } else {
      options[arg.slice(2)] = String(argv[i + 1] || "");
      i += 1;
    }
  }
  return options;
}

function resolveWindow(safari) {
  const windows = safeList(() => safari.windows());
  for (let i = 0; i < windows.length; i += 1) {
    const tab = safeValue(() => windows[i].currentTab());
    const url = safeString(() => tab.url());
    if (looksLikeKaistAuthUrl(url)) return windows[i];
  }
  if (windows.length > 0) return windows[0];
  safari.make({ new: "document" });
  delay(0.2);
  return safeValue(() => safari.windows()[0]);
}

function resolveTab(windowRef) {
  return safeValue(() => windowRef.currentTab());
}

function looksLikeKaistAuthUrl(url) {
  const lower = String(url || "").toLowerCase();
  return lower.includes("klms.kaist.ac.kr") || lower.includes("sso.kaist.ac.kr");
}

function runPageScript(tab, script) {
  return safeString(() => Application("/Applications/Safari.app").doJavaScript(script, { in: tab }));
}

function parseJson(value) {
  try {
    return JSON.parse(String(value || "{}"));
  } catch (_error) {
    return { ok: false, reason: "invalid-script-response" };
  }
}

function safeString(getter) {
  try {
    const value = getter();
    return value == null ? "" : String(value);
  } catch (_error) {
    return "";
  }
}

function safeValue(getter) {
  try {
    return getter();
  } catch (_error) {
    return null;
  }
}

function safeBoolean(getter) {
  try {
    return Boolean(getter());
  } catch (_error) {
    return false;
  }
}

function safeList(getter) {
  try {
    const value = getter();
    return Array.isArray(value) ? value : [];
  } catch (_error) {
    return [];
  }
}
