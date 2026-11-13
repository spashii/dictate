/* Download buttons. On a computer, pressing one opens the three install steps directly under it, in
   the button's place, and hides the price and requirements line meanwhile, so only the
   founding line stays. The download itself is the button's own link. On a phone there is no Mac to
   install on, so every Download button becomes a "Send to my Mac" button (or "Copy link" where the
   share sheet is missing) for the page address and never navigates to the DMG.
   Prices are written with a dollar sign; for visitors in a eurozone country the [data-price] amounts
   switch to euros, decided from the time zone, then the language region.
   The founding spots count is fetched once and appends "N spots left." to the founding sentence in every [data-left]; if the
   request fails the sentence stands alone. */
(function () {
  var STEPS = ["Open the DMG and drag Dictate to Applications.", "Open Dictate.", "In the window Dictate opens, press Activate in Browser."];
  var FOUNDING = "https://dictate.firstversion.in/api/activate/founding";

  // Touch, coarse pointer and a narrow screen together; the user agent alone is not trusted.
  function isPhone() {
    try {
      return !!(window.matchMedia && window.matchMedia("(hover: none) and (pointer: coarse)").matches &&
        Math.min(screen.width, screen.height) < 600);
    } catch (e) { return false; }
  }

  // Time zones of the 21 euro countries, France's overseas departments included because they use the euro.
  // Europe/Busingen is left out on purpose: Germany's exclave on the Swiss side bills in francs.
  var EURO_ZONES = ("Europe/Vienna Europe/Brussels Europe/Sofia Europe/Zagreb Asia/Nicosia Asia/Famagusta Europe/Nicosia " +
    "Europe/Tallinn Europe/Helsinki Europe/Mariehamn Europe/Paris Europe/Berlin Europe/Athens Europe/Dublin Eire " +
    "Europe/Rome Europe/Riga Europe/Vilnius Europe/Luxembourg Europe/Malta Europe/Amsterdam Europe/Monaco Europe/Andorra Europe/San_Marino Europe/Vatican Europe/Podgorica " +
    "Europe/Lisbon Atlantic/Madeira Atlantic/Azores Portugal Europe/Bratislava Europe/Ljubljana Europe/Madrid Africa/Ceuta Atlantic/Canary " +
    "Indian/Reunion Indian/Mayotte America/Martinique America/Guadeloupe America/Cayenne America/Marigot America/St_Barthelemy America/Miquelon").split(" ");
  var EURO_REGIONS = "AT BE BG HR CY EE FI FR DE GR IE IT LV LT LU MT NL PT SK SI ES MC AD SM VA ME XK".split(" ");

  // true for euro, false for dollar. The zone wins when it is a real place; only a missing or generic zone
  // (UTC, Etc/*) hands the decision to the browser's language regions.
  function inEurozone() {
    var zone = "";
    try { zone = Intl.DateTimeFormat().resolvedOptions().timeZone || ""; } catch (e) {}
    if (zone && !/^(UTC|GMT|Etc\/|Zulu|Universal|UCT|Greenwich)/i.test(zone)) return EURO_ZONES.indexOf(zone) >= 0;
    var langs = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || ""];
    for (var i = 0; i < langs.length; i++) {
      var m = /^[A-Za-z]{2,3}(?:-[A-Za-z]{4})?-([A-Za-z]{2})(?:-|$)/.exec(langs[i]);
      if (m) return EURO_REGIONS.indexOf(m[1].toUpperCase()) >= 0;
    }
    return false;
  }

  function currency() {
    if (!inEurozone()) return;
    var prices = document.querySelectorAll("[data-price]");
    for (var i = 0; i < prices.length; i++) prices[i].textContent = prices[i].textContent.replace("$", "\u20ac");
  }

  function liveRegion(parent) {
    var live = document.createElement("p");
    live.className = "sr";
    live.setAttribute("role", "status");
    live.setAttribute("aria-live", "polite");
    parent.appendChild(live);
    return live;
  }

  function founding() {
    var spots = document.querySelectorAll("[data-left]");
    if (!spots.length || !window.fetch) return;
    for (var k = 0; k < spots.length; k++) spots[k].setAttribute("data-base", spots[k].textContent);
    fetch(FOUNDING).then(function (r) { return r.ok ? r.json() : null; }).then(function (j) {
      if (j && Number.isInteger(j.left) && j.left >= 0) {
        for (var i = 0; i < spots.length; i++) { spots[i].textContent = spots[i].getAttribute("data-base") + " " + j.left + (j.left === 1 ? " spot left." : " spots left."); }
      }
    }).catch(function () {});
  }

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(function () { return legacyCopy(text); });
    }
    return legacyCopy(text);
  }
  function legacyCopy(text) {
    return new Promise(function (resolve, reject) {
      var t = document.createElement("textarea");
      t.value = text;
      t.setAttribute("readonly", "");
      t.style.cssText = "position:fixed;top:0;left:0;opacity:0";
      document.body.appendChild(t);
      t.select();
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(t);
      if (ok) resolve(); else reject(new Error("copy failed"));
    });
  }

  function phone() {
    var live = liveRegion(document.body);
    var canShare = typeof navigator.share === "function";
    var idle = canShare ? "Send to my Mac" : "Copy link";
    var buttons = [];
    var nodes = document.querySelectorAll("a[data-get], nav a.button.primary");
    for (var i = 0; i < nodes.length; i++) {
      var a = nodes[i];
      var b = document.createElement("button");
      b.type = "button";
      b.className = a.className;
      b.textContent = idle;
      a.parentNode.replaceChild(b, a);
      buttons.push(b);
    }
    // Hold the wider of the idle label and "Link copied" so the width does not change when the text swaps.
    buttons.forEach(function (b) {
      var w = b.offsetWidth;
      b.textContent = "Link copied";
      w = Math.max(w, b.offsetWidth);
      b.textContent = idle;
      if (w) b.style.minWidth = w + "px";
    });

    var timer = null;
    function copied(btn) {
      buttons.forEach(function (b) { b.textContent = idle; });
      btn.textContent = "Link copied";
      live.textContent = "Link copied";
      clearTimeout(timer);
      timer = setTimeout(function () {
        btn.textContent = idle;
        live.textContent = "";
      }, 2000);
    }
    function copy(url, btn) { copyText(url).then(function () { copied(btn); }, function () {}); }

    buttons.forEach(function (b) {
      b.addEventListener("click", function () {
        var btn = b;
        var url = location.href.split("#")[0];
        if (canShare) {
          var p;
          try { p = navigator.share({ url: url }); } catch (e) { p = Promise.reject(e); }
          Promise.resolve(p).then(null, function (err) {
            if (err && err.name === "AbortError") return;
            copy(url, btn);
          });
        } else {
          copy(url, btn);
        }
      });
    });
  }

  function desktop() {
    document.querySelectorAll("a[data-get]").forEach(function (a) {
      var group = a.closest(".get");
      if (!group) return;
      var actions = a.closest(".actions") || a.parentNode;
      var box = document.createElement("div");
      box.className = "steps";
      box.hidden = true;
      var inner = document.createElement("div");
      var ol = document.createElement("ol");
      STEPS.forEach(function (t) { var li = document.createElement("li"); li.textContent = t; ol.appendChild(li); });
      inner.appendChild(ol);
      box.appendChild(inner);
      // Right after the buttons, so the steps take the button's place on the same left edge.
      group.insertBefore(box, actions.nextSibling);
      var live = liveRegion(group);
      a.addEventListener("click", function () {
        group.querySelectorAll("[data-install-hide]").forEach(function (m) { m.hidden = true; });
        if (box.hidden) {
          box.hidden = false;
          void box.offsetHeight; // start from the closed state so the opening animates
          box.classList.add("is-open");
        }
        live.textContent = "Downloading. Three steps follow.";
      });
    });
  }

  currency();
  founding();
  if (isPhone()) phone(); else desktop();
})();
