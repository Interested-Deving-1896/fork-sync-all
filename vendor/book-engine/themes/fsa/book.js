// FSA Book — interactive enhancements
// Injected into every mdBook page via book.toml additional-js

(function () {
  "use strict";

  // ── Logo injection into sidebar ──────────────────────────────────────────
  function injectSidebarLogo() {
    var sidebar = document.querySelector(".sidebar-scrollbox");
    if (!sidebar) return;
    if (document.querySelector(".fsa-sidebar-logo")) return;

    var logoDiv = document.createElement("div");
    logoDiv.className = "fsa-sidebar-logo";
    logoDiv.style.cssText =
      "text-align:center;padding:1.2rem 1rem 0.5rem;border-bottom:1px solid rgba(255,255,255,0.1);margin-bottom:0.5rem;";

    var img = document.createElement("img");
    // Path relative to book root — works for GitHub Pages deployment
    img.src = window.__book_root
      ? window.__book_root + "assets/brand/logo-option-1.png"
      : "../assets/brand/logo-option-1.png";
    img.alt = "fork-sync-all";
    img.style.cssText =
      "max-width:100px;height:auto;border-radius:8px;opacity:0.92;";
    img.onerror = function () {
      this.style.display = "none";
    };

    logoDiv.appendChild(img);
    sidebar.insertBefore(logoDiv, sidebar.firstChild);
  }

  // ── Anchor links for all headings ────────────────────────────────────────
  function addHeadingAnchors() {
    var headings = document.querySelectorAll(
      ".content h1, .content h2, .content h3, .content h4"
    );
    headings.forEach(function (h) {
      if (!h.id) return;
      var anchor = document.createElement("a");
      anchor.href = "#" + h.id;
      anchor.className = "fsa-heading-anchor";
      anchor.innerHTML = " #";
      anchor.style.cssText =
        "opacity:0;color:var(--fsa-cyan);font-size:0.8em;text-decoration:none;margin-left:0.3em;transition:opacity 0.15s;";
      h.appendChild(anchor);
      h.addEventListener("mouseenter", function () {
        anchor.style.opacity = "1";
      });
      h.addEventListener("mouseleave", function () {
        anchor.style.opacity = "0";
      });
    });
  }

  // ── Copy-to-clipboard for code blocks ────────────────────────────────────
  function addCopyButtons() {
    var blocks = document.querySelectorAll("pre code");
    blocks.forEach(function (code) {
      var pre = code.parentElement;
      if (pre.querySelector(".fsa-copy-btn")) return;

      var btn = document.createElement("button");
      btn.className = "fsa-copy-btn";
      btn.textContent = "Copy";
      btn.style.cssText =
        "position:absolute;top:0.4rem;right:0.4rem;padding:0.2rem 0.6rem;" +
        "font-size:0.75rem;background:var(--fsa-blue);color:white;" +
        "border:none;border-radius:3px;cursor:pointer;opacity:0;transition:opacity 0.15s;";

      pre.style.position = "relative";
      pre.appendChild(btn);

      pre.addEventListener("mouseenter", function () {
        btn.style.opacity = "1";
      });
      pre.addEventListener("mouseleave", function () {
        btn.style.opacity = "0";
      });

      btn.addEventListener("click", function () {
        navigator.clipboard
          .writeText(code.textContent)
          .then(function () {
            btn.textContent = "Copied!";
            btn.style.background = "var(--fsa-cyan)";
            setTimeout(function () {
              btn.textContent = "Copy";
              btn.style.background = "var(--fsa-blue)";
            }, 1500);
          })
          .catch(function () {
            btn.textContent = "Error";
          });
      });
    });
  }

  // ── Active section highlight in sidebar ──────────────────────────────────
  function highlightActiveSidebarItem() {
    var path = window.location.pathname;
    var links = document.querySelectorAll(".sidebar a");
    links.forEach(function (a) {
      if (a.href && path.endsWith(a.getAttribute("href"))) {
        a.style.color = "var(--fsa-cyan-light)";
        a.style.fontWeight = "600";
      }
    });
  }

  // ── Init ──────────────────────────────────────────────────────────────────
  function init() {
    injectSidebarLogo();
    addHeadingAnchors();
    addCopyButtons();
    highlightActiveSidebarItem();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
