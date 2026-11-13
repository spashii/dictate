/* Download buttons. On a computer, pressing one opens the three install steps directly under it, in
   the button's place, and hides the price and requirements lines meanwhile. The download itself is the
   button's own link. On a phone there is no Mac to install on, so every Download button becomes a
   Share or Copy link button for the page address and never navigates to the DMG.
   The founding spots count is fetched once and fills every [data-left]; if the request fails the
   offer line stands alone. */
(function () {
  var STEPS = ["Open the DMG and drag Dictate to Applications.", "Open Dictate.", "Press Activate in Browser."];
  var FOUNDING = "https://dictate.firstversion.in/api/activate/founding";

  // Touch, coarse pointer and a narrow screen together; the user agent alone is not trusted.
  function isPhone() {
    try {
      return !!(window.matchMedia && window.matchMedia("(hover: none) and (pointer: coarse)").matches &&
        Math.min(screen.width, screen.height) < 600);
    } catch (e) { return false; }
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
    fetch(FOUNDING).then(function (r) { return r.ok ? r.json() : null; }).then(function (j) {
      if (j && Number.isInteger(j.left) && j.left >= 0) {
        for (var i = 0; i < spots.length; i++) { spots[i].textContent = j.left + " of 50 founding spots left"; spots[i].hidden = false; }
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
    var idle = canShare ? "Share" : "Copy link";
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
    // Hold the widest label so the button does not change width when its text swaps.
    buttons.forEach(function (b) {
      var w = b.offsetWidth;
      b.textContent = "Link copied";
      w = Math.max(w, b.offsetWidth);
      b.textContent = idle;
      if (w) b.style.minWidth = w + "px";
    });

    var timer = null;
    function copied() {
      buttons.forEach(function (b) { b.textContent = "Link copied"; });
      live.textContent = "Link copied";
      clearTimeout(timer);
      timer = setTimeout(function () {
        buttons.forEach(function (b) { b.textContent = "Copy link"; });
        live.textContent = "";
      }, 2000);
    }
    function copy(url) { copyText(url).then(copied, function () {}); }

    buttons.forEach(function (b) {
      b.addEventListener("click", function () {
        var url = location.href.split("#")[0];
        if (canShare) {
          var p;
          try { p = navigator.share({ url: url }); } catch (e) { p = Promise.reject(e); }
          Promise.resolve(p).then(null, function (err) {
            if (err && err.name === "AbortError") return;
            copy(url);
          });
        } else {
          copy(url);
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

  founding();
  if (isPhone()) phone(); else desktop();
})();
