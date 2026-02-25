(() => {
  const WTOnlineCountCache = {
    key: "wt_online_summary_v1",

    read() {
      try {
        const raw = window.localStorage?.getItem(this.key);
        if (!raw) return null;
        const parsed = JSON.parse(raw);
        const count = Number(parsed?.player_count);
        const max = Number(parsed?.visible_max);
        if (!Number.isFinite(count) || count < 0 || !Number.isFinite(max) || max <= 0) return null;
        return { player_count: count, visible_max: max, updated: Number(parsed?.updated) || 0 };
      } catch (_err) {
        return null;
      }
    },

    write(payload) {
      try {
        const count = Number(payload?.player_count ?? 0);
        const max = Number(payload?.visible_max ?? payload?.visible_max_players ?? 0);
        const updated = Number(payload?.updated ?? Math.floor(Date.now() / 1000));
        if (!Number.isFinite(count) || count < 0 || !Number.isFinite(max) || max <= 0) return;
        window.localStorage?.setItem(this.key, JSON.stringify({
          player_count: Math.max(0, count),
          visible_max: max,
          updated
        }));
      } catch (_err) {
        // ignore cache errors
      }
    },

    apply(labelEl, mirrorEl = null) {
      const cached = this.read();
      if (!cached) return false;
      const label = `${cached.player_count} / ${cached.visible_max}`;
      if (labelEl) labelEl.textContent = label;
      if (mirrorEl) mirrorEl.textContent = label;
      return true;
    }
  };

  window.WTOnlineCountCache = WTOnlineCountCache;

  // Handle flash close
  document.querySelectorAll("[role=alert][data-flash]").forEach((el) => {
    el.addEventListener("click", () => {
      el.setAttribute("hidden", "");
    });
  });

  if (!window.Phoenix || !window.LiveView) return;

  const Hooks = {};

  Hooks.ChatViewport = {
    mounted() {
      this.autoScroll = true;
      this.loadingOlder = false;
      this.baseTitle = document.title.replace(/^\(\d+\)\s*/, "").trim() || document.title;
      this.unreadCount = 0;
      this.prependAnchor = null;
      this.loadOlderReply = null;
      this.loadOlderRequestedAt = 0;
      this.wasNearBottom = true;
      this.seenIds = new Set();
      this.maxSeenId = 0;
      this.minSeenId = null;
      this.lastNavCountLabel = null;
      this.lastChatAgeLabel = null;
      this.onlineSummaryEndpoint = "/stats/online_summary.php";
      this.chatAgeEndpoint = "/stats/chat.php?limit=1&alerts_only=1";
      this.bindUiRefs();

      this.onScroll = () => {
        if (this.el.scrollTop <= 0 && !this.loadingOlder) {
          this.capturePrependAnchor();
          this.requestOlderMessages();
        }

        if (this.distanceFromBottom() > 20) {
          this.autoScroll = false;
          this.updateLockButton();
        }
      };

      this.onVisibility = () => {
        if (document.visibilityState === "visible") this.resetUnread();
      };

      this.el.addEventListener("scroll", this.onScroll, { passive: true });
      document.addEventListener("visibilitychange", this.onVisibility);
      window.addEventListener("focus", this.onVisibility);

      if (this.topBtn) this.topBtn.addEventListener("click", () => { this.el.scrollTop = 0; });
      if (this.bottomBtn) this.bottomBtn.addEventListener("click", () => {
        this.scrollToBottom();
        this.autoScroll = true;
        this.updateLockButton();
        this.resetUnread();
      });
      if (this.lockBtn) {
        this.lockBtn.addEventListener("click", () => {
          this.autoScroll = !this.autoScroll;
          this.updateLockButton();
          if (this.autoScroll) this.scrollToBottom();
        });
      }

      this.syncSeenRows();
      if (this.navCountEl) {
        const mirrorId = this.navCountEl.getAttribute("data-mirror-target");
        const mirror = mirrorId ? document.getElementById(mirrorId) : null;
        WTOnlineCountCache.apply(this.navCountEl, mirror);
      }
      this.updateLockButton();
      this.scrollToBottom();
      this.updateNavCount();
      this.updateChatAge();
      this.navCountTimer = setInterval(() => this.updateNavCount(), 10000);
      this.chatAgeTimer = setInterval(() => this.updateChatAge(), 60000);
    },

    beforeUpdate() {
      this.wasNearBottom = this.distanceFromBottom() < 24;
      this.preUpdateMaxSeenId = this.maxSeenId || 0;
      this.captureNavLabels();
    },

    updated() {
      this.bindUiRefs();
      this.restoreNavLabels();
      const rows = this.collectRows();
      const appended = rows.filter((row) => !this.seenIds.has(row.id) && row.id > (this.preUpdateMaxSeenId || 0));
      const appendedAlertCount = appended.reduce((sum, row) => sum + (row.alert ? 1 : 0), 0);

      this.syncSeenRows(rows);
      this.maybeRestorePrependAnchor();

      if (this.loadingOlder && Date.now() - this.loadOlderRequestedAt > 5000) {
        this.clearOlderLoadState();
      }

      if (appended.length > 0) {
        if (this.autoScroll || this.wasNearBottom) {
          this.scrollToBottom();
        } else if (document.visibilityState !== "visible" && appendedAlertCount > 0) {
          this.unreadCount += appendedAlertCount;
          this.updateTitle();
        }
      }
    },

    destroyed() {
      this.el.removeEventListener("scroll", this.onScroll);
      document.removeEventListener("visibilitychange", this.onVisibility);
      window.removeEventListener("focus", this.onVisibility);
      clearInterval(this.navCountTimer);
      clearInterval(this.chatAgeTimer);
      this.resetUnread();
    },

    bindUiRefs() {
      this.topBtn = document.getElementById("chat-btn-top");
      this.bottomBtn = document.getElementById("chat-btn-bottom");
      this.lockBtn = document.getElementById("chat-btn-lock");
      this.navCountEl = document.getElementById("nav-online-count");
      this.chatInput = document.getElementById("chat-input");
      this.navChatLabel = document.getElementById("nav-chat-label");
    },

    captureNavLabels() {
      if (this.navCountEl && this.navCountEl.isConnected) {
        const text = (this.navCountEl.textContent || "").trim();
        if (text && text !== "-- / --") this.lastNavCountLabel = text;
      }
      if (this.navChatLabel && this.navChatLabel.isConnected) {
        const text = (this.navChatLabel.textContent || "").trim();
        if (text && text !== "Last msg. --") this.lastChatAgeLabel = text;
      }
    },

    restoreNavLabels() {
      if (this.navCountEl) {
        const mirrorId = this.navCountEl.getAttribute("data-mirror-target");
        const mirror = mirrorId ? document.getElementById(mirrorId) : null;
        const appliedCache = WTOnlineCountCache.apply(this.navCountEl, mirror);
        if (!appliedCache && this.lastNavCountLabel) {
          this.navCountEl.textContent = this.lastNavCountLabel;
          if (mirror) mirror.textContent = this.lastNavCountLabel;
        }
      }
      if (this.navChatLabel && this.lastChatAgeLabel) {
        this.navChatLabel.textContent = this.lastChatAgeLabel;
      }
    },

    collectRows() {
      return Array.from(this.el.querySelectorAll("[data-chat-row]")).map((el) => ({
        id: Number(el.dataset.chatId || 0),
        alert: String(el.dataset.chatAlert || "0") === "1",
      })).filter((row) => Number.isFinite(row.id) && row.id > 0);
    },

    syncSeenRows(rows = this.collectRows()) {
      this.seenIds = new Set(rows.map((row) => row.id));
      this.maxSeenId = rows.reduce((max, row) => Math.max(max, row.id), 0);
      this.minSeenId = rows.length ? rows.reduce((min, row) => Math.min(min, row.id), rows[0].id) : null;
    },

    distanceFromBottom() {
      return Math.max(0, this.el.scrollHeight - (this.el.scrollTop + this.el.clientHeight));
    },

    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight;
    },

    updateLockButton() {
      if (!this.lockBtn) return;
      this.lockBtn.setAttribute("aria-pressed", this.autoScroll ? "true" : "false");
      this.lockBtn.classList.toggle("ring-2", this.autoScroll);
      this.lockBtn.classList.toggle("ring-emerald-400", this.autoScroll);
      this.lockBtn.classList.toggle("opacity-70", !this.autoScroll);
    },

    updateTitle() {
      document.title = this.unreadCount > 0 ? `(${this.unreadCount}) ${this.baseTitle}` : this.baseTitle;
    },

    resetUnread() {
      this.unreadCount = 0;
      this.updateTitle();
    },

    capturePrependAnchor() {
      const rows = Array.from(this.el.querySelectorAll("[data-chat-row]"));
      const containerRect = this.el.getBoundingClientRect();
      const anchor =
        rows.find((row) => row.getBoundingClientRect().bottom >= containerRect.top + 4) || rows[0] || null;

      if (!anchor) {
        this.prependAnchor = null;
        return;
      }

      const rect = anchor.getBoundingClientRect();
      this.prependAnchor = {
        id: Number(anchor.dataset.chatId || 0),
        offsetTop: rect.top - containerRect.top
      };
    },

    requestOlderMessages() {
      this.loadingOlder = true;
      this.loadOlderReply = null;
      this.loadOlderRequestedAt = Date.now();
      this.pushEvent("load_older", {}, (reply) => {
        this.loadOlderReply = reply || { prepended: false };
        this.maybeRestorePrependAnchor();
        if (!this.loadOlderReply.prepended) this.clearOlderLoadState();
      });
    },

    maybeRestorePrependAnchor() {
      if (!this.loadingOlder || !this.loadOlderReply || !this.loadOlderReply.prepended || !this.prependAnchor) {
        return;
      }

      const anchorRow = this.el.querySelector(`[data-chat-id="${this.prependAnchor.id}"]`);
      if (!anchorRow) return;

      const containerRect = this.el.getBoundingClientRect();
      const rowRect = anchorRow.getBoundingClientRect();
      const delta = (rowRect.top - containerRect.top) - this.prependAnchor.offsetTop;
      this.el.scrollTop += delta;
      this.clearOlderLoadState();
    },

    clearOlderLoadState() {
      this.loadingOlder = false;
      this.prependAnchor = null;
      this.loadOlderReply = null;
      this.loadOlderRequestedAt = 0;
    },

    async updateNavCount() {
      if (!this.navCountEl && !this.chatInput) return;

      try {
        const res = await fetch(this.onlineSummaryEndpoint, { cache: "no-store" });
        if (!res.ok) throw new Error("Request failed");

        const payload = await res.json();
        let count = Number(payload.player_count || 0);
        let max = Number(payload.visible_max || payload.visible_max_players || 0);
        if (!Number.isFinite(count) || count < 0) count = 0;
        if (!Number.isFinite(max) || max <= 0) max = 32;

        if (this.navCountEl) {
          const label = `${count} / ${max}`;
          this.navCountEl.textContent = label;
          this.lastNavCountLabel = label;
          const mirrorId = this.navCountEl.getAttribute("data-mirror-target");
          if (mirrorId) {
            const mirror = document.getElementById(mirrorId);
            if (mirror) mirror.textContent = label;
          }
        }
        WTOnlineCountCache.write({ player_count: count, visible_max: max, updated: payload.updated });

        if (this.chatInput) {
          const template = this.chatInput.getAttribute("data-dynamic-placeholder") || "Type to {count} players | All messages are deleted after 24hrs";
          this.chatInput.placeholder = template.replace("{count}", String(count));
        }
      } catch (_err) {
        // parity with PHP: ignore errors
      }
    },

    formatChatAge(diffSeconds) {
      if (!Number.isFinite(diffSeconds) || diffSeconds < 0) return "--";
      if (diffSeconds < 60) return "now";
      if (diffSeconds < 3600) {
        const minutes = Math.max(1, Math.floor(diffSeconds / 60));
        return `${minutes} minute${minutes === 1 ? "" : "s"} ago`;
      }
      if (diffSeconds < 86400) {
        const hours = Math.max(1, Math.floor(diffSeconds / 3600));
        return `${hours} hour${hours === 1 ? "" : "s"} ago`;
      }
      if (diffSeconds < 604800) {
        const days = Math.max(1, Math.floor(diffSeconds / 86400));
        return `${days} day${days === 1 ? "" : "s"} ago`;
      }
      const weeks = Math.floor(diffSeconds / 604800);
      if (weeks < 5) return `${weeks} week${weeks === 1 ? "" : "s"} ago`;
      const months = Math.max(1, Math.floor(diffSeconds / 2629800));
      return `${months} month${months === 1 ? "" : "s"} ago`;
    },

    async updateChatAge() {
      if (!this.navChatLabel) return;
      try {
        const res = await fetch(`${this.chatAgeEndpoint}&t=${Date.now()}`, { cache: "no-store" });
        if (!res.ok) throw new Error("Request failed");
        const payload = await res.json();
        if (!payload || payload.ok === false) throw new Error("Invalid chat payload");

        const messages = Array.isArray(payload.messages) ? payload.messages : [];
        if (messages.length === 0) {
          this.navChatLabel.textContent = "Last msg. --";
          this.lastChatAgeLabel = "Last msg. --";
          return;
        }

        const last = messages[messages.length - 1];
        const createdAt = Number(last.created_at || 0);
        const nowSeconds = Math.floor(Date.now() / 1000);
        this.navChatLabel.textContent = `Last msg. ${this.formatChatAge(nowSeconds - createdAt)}`;
        this.lastChatAgeLabel = this.navChatLabel.textContent;
      } catch (_err) {
        // parity with PHP: ignore errors
      }
    }
  };

  Hooks.ChatComposer = {
    mounted() {
      this.onKeyDown = (event) => {
        if (event.key !== "Enter") return;
        if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return;
        if (event.isComposing) return;

        event.preventDefault();

        const form = this.el.form || document.getElementById("chat-form");
        if (!form) return;

        if (typeof form.requestSubmit === "function") {
          form.requestSubmit();
        } else {
          form.submit();
        }
      };

      this.el.addEventListener("keydown", this.onKeyDown);
    },

    destroyed() {
      this.el.removeEventListener("keydown", this.onKeyDown);
    }
  };

  const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
  const { Socket } = window.Phoenix;
  const { LiveSocket } = window.LiveView;
  const liveSocket = new LiveSocket("/live", Socket, {
    params: { _csrf_token: csrfToken },
    hooks: Hooks
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
