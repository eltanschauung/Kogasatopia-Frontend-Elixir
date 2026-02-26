(() => {
  function $(selector, root = document) {
    return root.querySelector(selector);
  }

  function parsePayload() {
    const node = document.getElementById("info-data");
    if (!node) return null;

    try {
      return JSON.parse(node.textContent || "{}");
    } catch (_err) {
      return null;
    }
  }

  function createTile(item) {
    const link = document.createElement("a");
    link.href = "#";
    link.className = "on";
    link.title = item.title || item.name || "";
    link.addEventListener("click", (event) => event.preventDefault());

    const icon = document.createElement("img");
    icon.className = "btn-icon";
    icon.src = item.icon || "";

    const label = document.createElement("span");
    label.className = "btn-label";
    label.textContent = item.name || "";

    const effects = document.createElement("div");
    effects.className = "effects";

    (item.effects || []).forEach((segment) => {
      const span = document.createElement("span");
      span.className = `seg ${segment.cls || "neutral"}`;
      span.textContent = segment.text || "";
      effects.appendChild(span);
    });

    link.append(icon, label, effects);
    return link;
  }

  function boot() {
    const payload = parsePayload();
    if (!payload || !payload.items_by_class) return;

    const classBar = $("#class-bar");
    const container = $("#button-container");
    const search = $("#search");
    if (!classBar || !container || !search) return;

    const clickSound = new Audio("/info/sound/tf2-button-click.mp3");
    clickSound.preload = "auto";
    clickSound.volume = 0.5;

    const state = {
      activeClass: payload.active_class || "scout",
      filter: "",
      itemsByClass: payload.items_by_class
    };

    function syncClassButtons() {
      classBar.querySelectorAll(".class-btn").forEach((btn) => {
        btn.classList.toggle("active", btn.dataset.class === state.activeClass);
      });
    }

    function matchingItems() {
      if (!state.filter) return state.itemsByClass[state.activeClass] || [];

      const list = [];
      Object.values(state.itemsByClass).forEach((items) => {
        (items || []).forEach((item) => {
          if ((item.search || "").includes(state.filter)) list.push(item);
        });
      });
      return list;
    }

    function renderTiles() {
      const items = matchingItems();
      container.innerHTML = "";

      if (!items.length) {
        const empty = document.createElement("div");
        empty.className = "empty";
        empty.textContent = "No changes for this class match your filter.";
        container.appendChild(empty);
        return;
      }

      items.forEach((item) => container.appendChild(createTile(item)));
    }

    function setActiveClass(nextClass) {
      if (!nextClass || nextClass === state.activeClass) return;
      state.activeClass = nextClass;
      syncClassButtons();
      renderTiles();

      try {
        clickSound.currentTime = 0;
        clickSound.play().catch(() => {});
      } catch (_err) {}
    }

    classBar.querySelectorAll(".class-btn").forEach((btn) => {
      btn.addEventListener("click", () => setActiveClass(btn.dataset.class));
    });

    search.addEventListener("input", () => {
      state.filter = (search.value || "").trim().toLowerCase();
      renderTiles();
    });

    syncClassButtons();
    renderTiles();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot, { once: true });
  } else {
    boot();
  }
})();
