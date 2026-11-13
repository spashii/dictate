/* Download buttons: when one is pressed, the three steps that follow open under it. They are not in
   the page until then, so nothing below leaves a gap. The download itself is the button's own link. */
(function () {
  var STEPS = ["Open the DMG and drag Dictate to Applications.", "Open Dictate.", "Press Activate in Browser."];
  document.querySelectorAll("a[data-get]").forEach(function (a) {
    var group = a.closest(".get");
    if (!group) return;
    var box = document.createElement("div");
    box.className = "steps";
    box.hidden = true;
    var inner = document.createElement("div");
    var ol = document.createElement("ol");
    STEPS.forEach(function (t) { var li = document.createElement("li"); li.textContent = t; ol.appendChild(li); });
    inner.appendChild(ol);
    box.appendChild(inner);
    var live = document.createElement("p");
    live.className = "sr";
    live.setAttribute("role", "status");
    live.setAttribute("aria-live", "polite");
    group.appendChild(box);
    group.appendChild(live);
    a.addEventListener("click", function () {
      if (box.hidden) {
        box.hidden = false;
        void box.offsetHeight; // start from the closed state so the opening animates
        box.classList.add("is-open");
      }
      live.textContent = "Downloading. Three steps follow.";
    });
  });
})();
