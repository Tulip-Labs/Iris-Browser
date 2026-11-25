// Iris site: light, optional motion. The page works fully without this file.
(function () {
  "use strict";

  var root = document.documentElement;
  root.classList.add("js");

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  var finePointer = window.matchMedia("(hover: hover) and (pointer: fine)");

  // ---- scroll reveal ----
  var items = document.querySelectorAll(".reveal");
  if (reduce.matches || !("IntersectionObserver" in window)) {
    items.forEach(function (el) { el.classList.add("is-in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-in");
          io.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    items.forEach(function (el) { io.observe(el); });
  }

  // ---- the hero ring: its spectrum turns toward the pointer and refracts a little ----
  // Driven only by pointer events (one rAF per move at most); nothing runs while idle.
  var ring = document.querySelector("[data-ring]");
  if (ring && !reduce.matches) {
    var pending = false, lastX = 0, lastY = 0, turns = 0, lastDeg = null;

    var apply = function () {
      pending = false;
      var r = ring.getBoundingClientRect();
      var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
      var dx = lastX - cx, dy = lastY - cy;
      var deg = Math.atan2(dy, dx) * 180 / Math.PI + 90;
      // unwrap so the transition takes the short way round
      if (lastDeg !== null) {
        var d = deg - lastDeg;
        if (d > 180) turns -= 360; else if (d < -180) turns += 360;
      }
      lastDeg = deg;
      var dist = Math.min(1, Math.hypot(dx, dy) / Math.max(window.innerWidth, window.innerHeight));
      var shift = 6 * dist + 2;
      var len = Math.hypot(dx, dy) || 1;
      ring.style.setProperty("--rot", (deg + turns) + "deg");
      ring.style.setProperty("--tx", (dx / len * shift).toFixed(2) + "px");
      ring.style.setProperty("--ty", (dy / len * shift).toFixed(2) + "px");
    };

    window.addEventListener("pointermove", function (e) {
      if (e.pointerType !== "mouse" && e.pointerType !== "pen") return;
      lastX = e.clientX; lastY = e.clientY;
      if (!pending) { pending = true; requestAnimationFrame(apply); }
    }, { passive: true });

    document.addEventListener("pointerleave", function () {
      ring.style.setProperty("--tx", "0px");
      ring.style.setProperty("--ty", "0px");
    });
  }

  // ---- glass cards tilt slightly under the pointer ----
  if (!reduce.matches && finePointer.matches) {
    var MAX = 4; // degrees
    document.querySelectorAll("[data-tilt]").forEach(function (card) {
      card.addEventListener("pointermove", function (e) {
        var r = card.getBoundingClientRect();
        var px = (e.clientX - r.left) / r.width - 0.5;
        var py = (e.clientY - r.top) / r.height - 0.5;
        card.style.setProperty("--ry", (px * MAX).toFixed(2) + "deg");
        card.style.setProperty("--rx", (-py * MAX).toFixed(2) + "deg");
      });
      card.addEventListener("pointerleave", function () {
        card.style.setProperty("--rx", "0deg");
        card.style.setProperty("--ry", "0deg");
      });
    });
  }
})();
