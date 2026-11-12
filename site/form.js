// Signup forms: fill in where the visitor came from (utm_*, ?ref=), then sends it to the Dictate
// worker. Without JavaScript the form still posts normally and the worker redirects back here.
const q = new URLSearchParams(location.search);
const setIn = form => (name, value) => { const el = form.querySelector(`[name="${name}"]`); if (el && value) el.value = value.slice(0, 64); };
document.querySelectorAll("form.signup").forEach(form => {
const set = setIn(form);
set("utm_source", q.get("utm_source")); set("utm_medium", q.get("utm_medium")); set("utm_campaign", q.get("utm_campaign"));
// Referring site host only (never the full URL), and not this site itself.
const refHost = (() => { try { const h = new URL(document.referrer).hostname.replace(/^www\./, ""); return h && h !== "spashii.github.io" ? h : ""; } catch { return ""; } })();
set("source", q.get("ref") || q.get("utm_source") || refHost || "site");

const err = form.querySelector(".err");
const button = form.querySelector("button");
form.addEventListener("submit", async (e) => {
  e.preventDefault();
  err.hidden = true;
  button.disabled = true;
  try {
    const res = await fetch(form.action, { method: "POST", body: new FormData(form), headers: { accept: "application/json" } });
    const out = await res.json().catch(() => ({}));
    if (res.ok && out.ok) { location.href = "check-inbox.html"; return; }
    err.textContent = out.error || "That did not go through. Please try again.";
  } catch {
    err.textContent = "We could not reach the server. Please try again.";
  }
  err.hidden = false;
  button.disabled = false;
  if (window.turnstile) window.turnstile.reset();
});
});
