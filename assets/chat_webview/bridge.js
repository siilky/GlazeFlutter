class Bridge {
  constructor(renderer, virtualList) {
    this.renderer = renderer;
    this.virtualList = virtualList;
    this._pendingRequests = new Map();
    this._requestCounter = 0;
    this._setupSmoothScroll();
    this._setupScrollListener();
    this._setupInteractionListener();
  }

  _sendToFlutter(name, args) {
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler(name, ...args);
    }
  }

  _requestToFlutter(name, args, timeoutMs = 60000) {
    return new Promise((resolve, reject) => {
      const requestId = `${name}_${++this._requestCounter}`;
      const timer = setTimeout(() => {
        this._pendingRequests.delete(requestId);
        reject(new Error(`Bridge request "${name}" timed out after ${timeoutMs}ms`));
      }, timeoutMs);

      this._pendingRequests.set(requestId, { resolve, reject, timer });
      this._sendToFlutter(name, [requestId, ...args]);
    });
  }

  _resolveRequest(requestId, result) {
    const pending = this._pendingRequests.get(requestId);
    if (!pending) return;
    clearTimeout(pending.timer);
    this._pendingRequests.delete(requestId);
    pending.resolve(result);
  }

  _rejectRequest(requestId, error) {
    const pending = this._pendingRequests.get(requestId);
    if (!pending) return;
    clearTimeout(pending.timer);
    this._pendingRequests.delete(requestId);
    pending.reject(new Error(error));
  }

  _setupSmoothScroll() {
    const container = this.virtualList.container;
    let scrollTarget = null;
    let isScrolling = false;

    container.addEventListener('wheel', (e) => {
      const target = e.target;
      if (target && target.closest) {
        if (target.closest('textarea, input, [contenteditable="true"]')) return;
      }
      e.preventDefault();

      const delta = e.deltaY;
      const step = 60;
      if (!scrollTarget) {
        scrollTarget = container.scrollTop;
      }
      scrollTarget += delta > 0 ? step : -step;
      scrollTarget = Math.max(0, Math.min(scrollTarget, container.scrollHeight - container.clientHeight));

      if (!isScrolling) {
        isScrolling = true;
        const animate = () => {
          const current = container.scrollTop;
          const diff = scrollTarget - current;
          if (Math.abs(diff) < 1) {
            container.scrollTop = scrollTarget;
            isScrolling = false;
            scrollTarget = null;
            this.virtualList._scheduleUpdate();
            return;
          }
          container.scrollTop = current + diff * 0.3;
          this.virtualList._scheduleUpdate();
          requestAnimationFrame(animate);
        };
        requestAnimationFrame(animate);
      }
    }, { passive: false });
  }

  _setupScrollListener() {
    this.virtualList.container.addEventListener('scroll', () => {
      if (this.virtualList.isNearTop(100)) {
        this._sendToFlutter('onLoadMore', []);
      }
    });
  }

  _setupInteractionListener() {
    document.addEventListener('click', (e) => {
      const link = e.target.closest('a');
      if (link) {
        e.preventDefault();
        this._sendToFlutter('onLinkClick', [link.href]);
      }

      const img = e.target.closest('img');
      if (img && img.src) {
        this._sendToFlutter('onImageClick', [img.src]);
      }

      const menuBtn = e.target.closest('.meta-menu-btn');
      if (menuBtn) {
        const id = menuBtn.dataset.messageId;
        const msgEl = document.querySelector(`[data-message-id="${id}"]`);
        if (msgEl) {
          const isUser = msgEl.classList.contains('message-user');
          const contentEl = msgEl.querySelector('.message-content');
          let content = '';
          if (contentEl && contentEl.shadowRoot) {
            const msgDiv = contentEl.shadowRoot.querySelector('.glaze-message');
            content = msgDiv ? msgDiv.textContent : '';
          }
          this._sendToFlutter('onMessageContext', [JSON.stringify({ id, isUser, isSystem: false, content })]);
        }
        return;
      }

      const swipeBtn = e.target.closest('.swipe-btn');
      if (swipeBtn) {
        const action = swipeBtn.dataset.action;
        const id = swipeBtn.dataset.messageId;
        this._sendToFlutter('onSwipe', [JSON.stringify({ id, direction: action === 'swipe-right' ? 'right' : 'left' })]);
        return;
      }

      const regenBtn = e.target.closest('.regen-btn');
      if (regenBtn) {
        const id = regenBtn.dataset.messageId;
        this._sendToFlutter('onRegenerate', [id]);
        return;
      }

      this._hideSelectionBar();
    });

    document.addEventListener('selectionchange', () => {
      const sel = window.getSelection();
      if (sel && sel.toString().trim().length > 0) {
        this._showSelectionBar(sel.toString().trim());
      } else {
        this._hideSelectionBar();
      }
    });

    document.addEventListener('contextmenu', (e) => {
      const msgEl = e.target.closest('.message');
      if (!msgEl) return;
      e.preventDefault();

      const id = msgEl.dataset.messageId;
      const isUser = msgEl.classList.contains('message-user');
      const isSystem = msgEl.classList.contains('message-system');

      const contentEl = msgEl.querySelector('.message-content');
      let content = '';
      if (contentEl && contentEl.shadowRoot) {
        const msgDiv = contentEl.shadowRoot.querySelector('.glaze-message');
        content = msgDiv ? msgDiv.textContent : '';
      }

      this._sendToFlutter('onMessageContext', [JSON.stringify({
        id, isUser, isSystem, content
      })]);
    });
  }

  _showSelectionBar(text) {
    let bar = document.getElementById('selection-bar');
    if (!bar) {
      bar = document.createElement('div');
      bar.id = 'selection-bar';
      bar.className = 'selection-bar';
      bar.innerHTML = '<button class="sel-btn" data-action="copy">Copy</button><button class="sel-btn" data-action="quote">Quote</button>';
      bar.addEventListener('click', (e) => {
        const btn = e.target.closest('.sel-btn');
        if (!btn) return;
        const action = btn.dataset.action;
        this._sendToFlutter('onSelectionAction', [JSON.stringify({ action, text: this._selectedText })]);
        this._hideSelectionBar();
        window.getSelection().removeAllRanges();
      });
      document.body.appendChild(bar);
    }
    this._selectedText = text;
    bar.style.display = 'flex';
  }

  _hideSelectionBar() {
    const bar = document.getElementById('selection-bar');
    if (bar) bar.style.display = 'none';
  }

  _hideLoadingScreen() {
    const loading = document.getElementById('loading-screen');
    if (loading) {
      loading.style.opacity = '0';
      setTimeout(() => loading.remove(), 200);
    }
  }

  setMessages(messagesJson) {
    const container = document.getElementById('chat-container') || document.body;
    if (!container.classList.contains('layout-bubble') &&
        !container.classList.contains('layout-standard') &&
        !container.classList.contains('layout-cards')) {
      container.classList.add('layout-bubble');
    }

    const messages = JSON.parse(messagesJson);
    const ids = [];
    const elements = [];
    for (const msg of messages) {
      ids.push(msg.id);
      elements.push(this.renderer.renderMessage(msg));
    }
    this.virtualList.setMessagesBatch(ids, elements);

    requestAnimationFrame(() => {
      this.virtualList.scrollToBottom();
      this._hideLoadingScreen();
    });
  }

  appendMessage(messageJson) {
    const msg = JSON.parse(messageJson);
    const el = this.renderer.renderMessage(msg);
    this.virtualList.append(msg.id, el);
    this.virtualList.scrollToBottom();
  }

  appendMessages(messagesJson) {
    const messages = JSON.parse(messagesJson);
    messages.forEach(msg => {
      const el = this.renderer.renderMessage(msg);
      this.virtualList.append(msg.id, el);
    });
  }

  prependMessages(messagesJson) {
    const messages = JSON.parse(messagesJson);
    const scrollBefore = this.virtualList.container.scrollHeight;
    messages.forEach(msg => {
      const el = this.renderer.renderMessage(msg);
      this.virtualList.prepend(msg.id, el);
    });
    const scrollAfter = this.virtualList.container.scrollHeight;
    this.virtualList.container.scrollTop = scrollAfter - scrollBefore;
  }

  updateMessage(messageJson) {
    const msg = JSON.parse(messageJson);
    this.renderer.updateMessage(msg.id, msg.text, msg.isUser);
  }

  removeMessage(messageId) {
    this.virtualList.remove(messageId);
  }

  clearAll() {
    this.virtualList.clear();
  }

  scrollToBottom() {
    this.virtualList.scrollToBottom();
  }

  scrollToMessage(messageId) {
    this.virtualList.scrollToMessage(messageId);
  }

  setSearch(query, activeIndex) {
    this.renderer.setSearch(query, activeIndex);
  }

  setChatFont(fontFamily, fontDataUrl, fontSize, letterSpacing) {
    const root = document.documentElement;
    if (fontSize != null) root.style.setProperty('--font-size', fontSize + 'px');
    if (letterSpacing != null) root.style.setProperty('--letter-spacing', letterSpacing + 'px');

    let fontFace = document.getElementById('custom-font-face');
    if (fontDataUrl) {
      if (!fontFace) {
        fontFace = document.createElement('style');
        fontFace.id = 'custom-font-face';
        document.head.appendChild(fontFace);
      }
      fontFace.textContent = `@font-face { font-family: '${fontFamily || 'CustomChatFont'}'; src: url('${fontDataUrl}'); font-display: swap; }`;
      root.style.setProperty('--font-family', `'${fontFamily || 'CustomChatFont'}', sans-serif`);
    } else {
      if (fontFace) fontFace.remove();
      if (fontFamily) {
        root.style.setProperty('--font-family', fontFamily);
      } else {
        root.style.removeProperty('--font-family');
      }
    }
  }

  applyTheme(themeJson) {
    const theme = JSON.parse(themeJson);
    const container = document.getElementById('chat-container') || document.body;

    for (const [key, value] of Object.entries(theme)) {
      if (key === 'chat-layout') {
        container.classList.remove('layout-bubble', 'layout-standard', 'layout-cards');
        if (value) {
          container.classList.add(`layout-${value}`);
        }
        continue;
      }
      document.documentElement.style.setProperty(`--${key}`, value);
    }
  }

  setBottomPadding(px) {
    const container = document.getElementById('chat-container') || document.body;
    container.style.paddingBottom = px + 'px';
  }

  applyLayout(layout) {
    const container = document.getElementById('chat-container') || document.body;
    container.classList.remove('layout-bubble', 'layout-standard', 'layout-cards', 'layout-default', 'layout-system');
    const cls = layout || 'bubble';
    container.classList.add(`layout-${cls}`);
  }

  startEdit(messageId) {
    const scrollPos = this.virtualList.container.scrollTop;
    const msgEl = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!msgEl) return;

    const rawText = msgEl.dataset.rawText || '';
    const reasoning = msgEl.dataset.reasoning || '';
    let editText = rawText;
    if (reasoning) {
      editText = `<think>\n${reasoning}\n</think>\n${rawText}`;
    }

    const contentEl = msgEl.querySelector('.message-content');
    if (!contentEl || !contentEl.shadowRoot) return;
    const msgDiv = contentEl.shadowRoot.querySelector('.glaze-message');

    msgDiv.innerHTML = '';
    const textarea = document.createElement('textarea');
    textarea.className = 'edit-textarea';
    textarea.value = editText;
    textarea.dataset.originalText = editText;
    msgDiv.appendChild(textarea);

    textarea.addEventListener('input', () => {
      textarea.style.height = 'auto';
      textarea.style.height = Math.max(80, textarea.scrollHeight) + 'px';
    });
    textarea.style.height = Math.max(80, textarea.scrollHeight + 20) + 'px';
    textarea.focus();

    msgEl.classList.add('message-editing');

    const metaRow = msgEl.querySelector('.message-meta-right');
    if (metaRow) {
      metaRow.dataset.originalHtml = metaRow.innerHTML;
      metaRow.innerHTML = '';
      const cancelBtn = document.createElement('button');
      cancelBtn.className = 'edit-btn edit-cancel-btn';
      cancelBtn.textContent = '✖';
      cancelBtn.dataset.messageId = messageId;
      cancelBtn.addEventListener('click', () => this._sendToFlutter('onEditCancel', [messageId]));
      metaRow.appendChild(cancelBtn);

      const saveBtn = document.createElement('button');
      saveBtn.className = 'edit-btn edit-save-btn';
      saveBtn.textContent = '✔';
      saveBtn.dataset.messageId = messageId;
      saveBtn.addEventListener('click', () => {
        const text = textarea.value;
        this._sendToFlutter('onEditSave', [messageId, text]);
      });
      metaRow.appendChild(saveBtn);
    }

    this.virtualList.container.scrollTop = scrollPos;
  }

  stopEdit(messageId) {
    const msgEl = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!msgEl) return;
    msgEl.classList.remove('message-editing');
    const metaRow = msgEl.querySelector('.message-meta-right');
    if (metaRow && metaRow.dataset.originalHtml !== undefined) {
      metaRow.innerHTML = metaRow.dataset.originalHtml;
      delete metaRow.dataset.originalHtml;
    }
  }

  setBackgroundImage(url, blur, opacity) {
    let bg = document.getElementById('bg-layer');
    if (!bg) {
      bg = document.createElement('div');
      bg.id = 'bg-layer';
      document.body.insertBefore(bg, document.body.firstChild);
    }
    if (url) {
      bg.style.backgroundImage = `url('${url}')`;
      bg.style.display = 'block';
    } else {
      bg.style.backgroundImage = '';
      bg.style.display = 'none';
    }
    bg.style.filter = `blur(${blur || 0}px)`;
    bg.style.opacity = opacity != null ? opacity : 1;
  }
}