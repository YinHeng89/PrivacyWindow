/* 隐私窗口 — 官网交互
   Two things only: the focus demo, and remembering the colour scheme. No
   tracking, no network calls. */

(function () {
  "use strict";

  /* ---------- colour scheme ---------- */

  var STORAGE_KEY = "pw-theme";
  var root = document.documentElement;

  function apply(theme) {
    root.setAttribute("data-theme", theme);
    var toggle = document.getElementById("theme-toggle");
    if (toggle) {
      toggle.setAttribute("aria-label", theme === "dark" ? "切换到浅色配色" : "切换到深色配色");
    }
  }

  var stored = null;
  try {
    stored = window.localStorage.getItem(STORAGE_KEY);
  } catch (error) {
    stored = null; // Private mode, or storage blocked: fall back to the system.
  }

  if (stored === "dark" || stored === "light") {
    apply(stored);
  } else if (window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches) {
    apply("light");
  }

  var toggle = document.getElementById("theme-toggle");
  if (toggle) {
    toggle.addEventListener("click", function () {
      var next = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
      apply(next);
      try {
        window.localStorage.setItem(STORAGE_KEY, next);
      } catch (error) {
        /* Not being remembered is a small enough cost; the toggle still works. */
      }
    });
  }

  /* ---------- focus demo ---------- */

  var demo = document.getElementById("demo");
  var caption = document.getElementById("demo-caption");

  if (demo && caption) {
    var windows = Array.prototype.slice.call(demo.querySelectorAll(".demo-win"));

    function focusOn(target) {
      windows.forEach(function (win) {
        win.classList.toggle("is-focused", win === target);
      });
      var label = target.querySelector(".demo-title");
      if (label) {
        caption.textContent = "焦点在「" + label.textContent + "」—— 其余全部模糊";
      }
    }

    windows.forEach(function (win) {
      win.addEventListener("click", function () { focusOn(win); });
      win.addEventListener("keydown", function (event) {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          focusOn(win);
        }
      });
    });
  }
})();
