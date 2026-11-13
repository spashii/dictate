/* Remembers where a visitor came from (first touch only) and passes it on. No cookie: the download
   button carries it in its link, and the activation page sends it with the code request.
   The values are campaign names, nothing that identifies a person. */
(function () {
  var KEY = "dictate-src", FIELDS = ["utm_source", "utm_medium", "utm_campaign", "ref"], found = null;
  try { found = JSON.parse(localStorage.getItem(KEY) || "null"); } catch (e) {}
  if (!found || typeof found !== "object") {
    var q = new URLSearchParams(location.search), out = {}, any = false;
    FIELDS.forEach(function (k) { var v = (q.get(k) || "").slice(0, 64); if (v) { out[k] = v; any = true; } });
    if (!any) {
      try {
        var h = new URL(document.referrer).hostname.replace(/^www\./, "");
        if (h && h !== location.hostname) { out.ref = h.slice(0, 64); any = true; }
      } catch (e) {}
    }
    found = any ? out : {};
    if (any) { try { localStorage.setItem(KEY, JSON.stringify(out)); } catch (e) {} }
  }
  window.dictateAttribution = found;
  var qs = new URLSearchParams();
  FIELDS.forEach(function (k) { if (found[k]) qs.set(k, found[k]); });
  var s = qs.toString();
  if (s) document.querySelectorAll("a[data-get]").forEach(function (a) { a.href += (a.href.indexOf("?") < 0 ? "?" : "&") + s; });
})();
