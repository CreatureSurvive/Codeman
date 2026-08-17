/**
 * @fileoverview Mobile device support: detection, keyboard handling, and swipe navigation.
 *
 * Defines three singleton objects that manage mobile-specific behavior:
 *
 * - MobileDetection — Device type detection (mobile/tablet/desktop), touch capability,
 *   iOS/Safari identification, and body class management for CSS targeting.
 * - KeyboardHandler — Virtual keyboard show/hide detection via visualViewport API,
 *   toolbar/accessory bar repositioning, terminal resize on keyboard open/close,
 *   and input scroll-into-view. Uses 100px threshold for iOS address bar drift.
 * - SwipeHandler — Horizontal swipe detection on the terminal area for session switching.
 *   80px minimum distance, 300ms maximum time, 100px max vertical drift.
 *
 * All three have init()/cleanup() lifecycle methods. They are re-initialized after SSE
 * reconnect (in handleInit) to prevent stale closures.
 *
 * @globals {object} MobileDetection
 * @globals {object} KeyboardHandler
 * @globals {object} SwipeHandler
 *
 * @dependency keyboard-accessory.js (KeyboardAccessoryBar reference in KeyboardHandler.onKeyboardShow, soft — guarded with typeof check)
 * @loadorder 2 of 15 — loaded after constants.js, before voice-input.js
 */

// Codeman — Mobile detection, keyboard handling, and swipe navigation
// Loaded after constants.js, before app.js

// ═══════════════════════════════════════════════════════════════
// Mobile Detection
// ═══════════════════════════════════════════════════════════════

/**
 * MobileDetection - Detects device type and touch capability.
 * Updates body classes for CSS targeting.
 */
const MobileDetection = {
  /** Check if device supports touch input */
  isTouchDevice() {
    return (
      'ontouchstart' in window ||
      navigator.maxTouchPoints > 0 ||
      (window.matchMedia && window.matchMedia('(pointer: coarse)').matches)
    );
  },

  /**
   * Check whether this browser belongs to a handheld device.
   *
   * Unlike getDeviceType(), this classification must remain stable when a
   * foldable changes posture. An unfolded phone can expose a desktop-width
   * viewport, but it still needs the same per-device settings that were saved
   * while folded. User-Agent Client Hints are preferred where available; the
   * legacy token fallback covers Android WebView and iPhone browsers.
   */
  isHandheldDevice() {
    if (!this.isTouchDevice()) return false;

    const userAgent = navigator.userAgent || '';

    // Prefer explicit UA form-factor signals. Besides matching real browsers,
    // this avoids Chromium emulation reporting userAgentData.mobile=true for
    // an iPad/tablet context created with isMobile=true.
    if (/iPad|Tablet|Silk|PlayBook|Kindle|Windows NT|CrOS|Macintosh/i.test(userAgent)) {
      return false;
    }
    if (/Android/i.test(userAgent) && !/Mobile/i.test(userAgent)) return false;
    if (/Mobi|iPhone|iPod/i.test(userAgent)) return true;

    const uaDataMobile = navigator.userAgentData?.mobile;
    if (typeof uaDataMobile === 'boolean') return uaDataMobile;

    return false;
  },

  /** Check if device is iOS (iPhone, iPad, iPod) */
  isIOS() {
    return (
      /iPad|iPhone|iPod/.test(navigator.userAgent) ||
      (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
    );
  },

  /** Check if browser is Safari */
  isSafari() {
    return /^((?!chrome|android).)*safari/i.test(navigator.userAgent);
  },

  /** Check if the app is running from an installed PWA/home-screen shell */
  isStandalonePwa() {
    return (
      window.matchMedia?.('(display-mode: standalone)').matches ||
      window.matchMedia?.('(display-mode: fullscreen)').matches ||
      window.navigator.standalone === true
    );
  },

  /** Check if the page is running inside a native Capacitor shell */
  isNativeShell() {
    return !!window.Capacitor || document.documentElement.classList.contains('codeman-native');
  },

  /** Check if screen is small (phone-sized, <430px) */
  isSmallScreen() {
    return window.innerWidth < 430;
  },

  /** Check if screen is medium (tablet-sized, 430-768px) */
  isMediumScreen() {
    return window.innerWidth >= 430 && window.innerWidth < 768;
  },

  /** Get device type based on screen width */
  getDeviceType() {
    const width = window.innerWidth;
    if (width < 430) return 'mobile';
    if (width < 768) return 'tablet';
    return 'desktop';
  },

  /** Update body classes based on device detection */
  updateBodyClass() {
    const body = document.body;
    const deviceType = this.getDeviceType();
    const isTouch = this.isTouchDevice();

    // Remove existing device classes
    body.classList.remove(
      'device-mobile',
      'device-tablet',
      'device-desktop',
      'touch-device',
      'ios-device',
      'safari-browser',
      'pwa-standalone',
      'codeman-native'
    );

    // Add current device class
    body.classList.add(`device-${deviceType}`);

    // Add touch device class if applicable
    if (isTouch) {
      body.classList.add('touch-device');
    }

    // Add iOS-specific class for safe area handling
    if (this.isIOS()) {
      body.classList.add('ios-device');
    }

    // Add Safari class for browser-specific fixes
    if (this.isSafari()) {
      body.classList.add('safari-browser');
    }

    if (this.isStandalonePwa()) {
      body.classList.add('pwa-standalone');
    }

    if (this.isNativeShell()) {
      body.classList.add('codeman-native');
      document.documentElement.classList.add('codeman-native');
    }
  },

  /** Set --app-height CSS variable from visual viewport.
   *  On iPad Safari with tabs, 100vh extends behind the tab bar.
   *  visualViewport.height reflects the actual visible area.
   *  Skips when virtual keyboard is open — KeyboardHandler manages
   *  layout via translateY + paddingBottom; shrinking --app-height
   *  would double-count and leave zero space for the terminal. */
  updateAppHeight() {
    if (typeof KeyboardHandler !== 'undefined' && KeyboardHandler.keyboardVisible) return;
    const viewport = window.visualViewport;
    const vh = viewport?.height || window.innerHeight;
    const top = viewport?.offsetTop || 0;
    document.documentElement.style.setProperty('--app-height', `${vh}px`);
    document.documentElement.style.setProperty('--app-top', `${top}px`);
  },

  /** Initialize mobile detection and set up resize listener */
  init() {
    this.updateBodyClass();
    this.updateAppHeight();

    // Update --app-height on viewport resize (orientation, tab bar toggle)
    if (window.visualViewport) {
      this._appHeightHandler = () => this.updateAppHeight();
      window.visualViewport.addEventListener('resize', this._appHeightHandler);
      window.visualViewport.addEventListener('scroll', this._appHeightHandler);
    }

    // Debounced resize handler
    let resizeTimeout;
    this._resizeHandler = () => {
      clearTimeout(resizeTimeout);
      resizeTimeout = setTimeout(() => {
        this.updateBodyClass();
        this.updateAppHeight();
        // Whether the session sidebar is a docked column or a modal overlay is
        // decided at 1024px, so crossing that width has to re-sync the drawer
        // state — otherwise the `inert`/aria-hidden set on a closed overlay
        // drawer survives into the docked rail and makes it unclickable.
        if (typeof app !== 'undefined') app.applySessionListLayout?.();
        // Tab auto-wrap is width-driven, so it must re-evaluate on resize — the only
        // other trigger is a tab content render. No-op on mobile/tablet (method bails).
        if (typeof app !== 'undefined') app.updateTabOverflowMode?.();
      }, 100);
    };
    window.addEventListener('resize', this._resizeHandler);

    // iOS: prevent pinch-to-zoom (Safari ignores user-scalable=no since iOS 10)
    if (this.isIOS()) {
      this._gestureStartHandler = (e) => e.preventDefault();
      this._gestureChangeHandler = (e) => e.preventDefault();
      document.addEventListener('gesturestart', this._gestureStartHandler);
      document.addEventListener('gesturechange', this._gestureChangeHandler);
    }
  },

  /** Remove event listeners */
  cleanup() {
    if (this._resizeHandler) {
      window.removeEventListener('resize', this._resizeHandler);
      this._resizeHandler = null;
    }
    if (this._gestureStartHandler) {
      document.removeEventListener('gesturestart', this._gestureStartHandler);
      document.removeEventListener('gesturechange', this._gestureChangeHandler);
      this._gestureStartHandler = null;
      this._gestureChangeHandler = null;
    }
    if (this._appHeightHandler && window.visualViewport) {
      window.visualViewport.removeEventListener('resize', this._appHeightHandler);
      window.visualViewport.removeEventListener('scroll', this._appHeightHandler);
      this._appHeightHandler = null;
    }
  },
};

// ═══════════════════════════════════════════════════════════════
// Mobile Keyboard Handler
// ═══════════════════════════════════════════════════════════════

/**
 * KeyboardHandler - Simple handler to scroll inputs into view when keyboard appears.
 * Uses focusin event and scrollIntoView - keeps it simple and reliable.
 * Also handles terminal scrolling and toolbar repositioning via visualViewport API.
 */
const KeyboardHandler = {
  VIEWPORT_SETTLE_MS: 80,
  lastViewportHeight: 0,
  keyboardVisible: false,
  initialViewportHeight: 0,
  _viewportSettleTimer: null,
  _settleRestoreScroll: false,
  _settlePending: false,
  _nativeKeyboardHeight: 0,
  _nativeKeyboardListeners: [],
  _nativeKeyboardListenerPromises: [],
  // Scroll intent captured at the start of a settle cycle (#259). `true` =
  // following live output, `false` = reading history and _settleAnchorY holds
  // the top visible line to return to.
  _settleFollowing: true,
  _settleAnchorY: null,

  /** Initialize keyboard handling */
  init() {
    // Only initialize on touch devices
    if (!MobileDetection.isTouchDevice()) return;

    this.initialViewportHeight = window.visualViewport?.height || window.innerHeight;
    this.lastViewportHeight = this.initialViewportHeight;

    // Scroll focused form controls above the virtual keyboard. iOS Safari emits
    // several visualViewport updates during the keyboard animation, so retry
    // after the first focus instead of trusting a single early measurement.
    this._focusinHandler = (e) => {
      const target = e.target;
      if (!this.isInputElement(target)) return;

      this.scheduleFocusedInputScroll(target);
    };
    document.addEventListener('focusin', this._focusinHandler);

    this._touchInputHandler = (e) => {
      const target = e.target;
      if (!this.isInputElement(target)) return;
      this.scheduleFocusedInputScroll(target);
    };
    document.addEventListener('touchstart', this._touchInputHandler, { passive: true, capture: true });

    // Use visualViewport to detect keyboard and reposition toolbar
    if (window.visualViewport) {
      this._viewportResizeHandler = () => {
        this.handleViewportResize();
      };
      this._viewportScrollHandler = () => {
        this.updateLayoutForKeyboard();
        this.scrollFocusedInputIntoView();
      };
      window.visualViewport.addEventListener('resize', this._viewportResizeHandler);
      // Also handle scroll (iOS scrolls viewport when keyboard appears)
      window.visualViewport.addEventListener('scroll', this._viewportScrollHandler);
    }

    const nativeKeyboard = window.Capacitor?.Plugins?.Keyboard;
    if (MobileDetection.isNativeShell?.() && nativeKeyboard?.addListener) {
      const addNativeListener = (eventName, handler) => {
        try {
          const result = nativeKeyboard.addListener(eventName, handler);
          if (result && typeof result.then === 'function') {
            this._nativeKeyboardListenerPromises.push(
              result
                .then((listener) => {
                  if (listener) this._nativeKeyboardListeners.push(listener);
                  return listener;
                })
                .catch(() => null)
            );
          } else if (result) {
            this._nativeKeyboardListeners.push(result);
          }
        } catch {
          // VisualViewport remains the fallback when native keyboard events fail.
        }
      };
      addNativeListener('keyboardWillShow', (info) => this.handleNativeKeyboardShow(info));
      addNativeListener('keyboardDidShow', (info) => this.handleNativeKeyboardShow(info));
      addNativeListener('keyboardWillHide', () => this.handleNativeKeyboardHide());
      addNativeListener('keyboardDidHide', () => this.handleNativeKeyboardHide());
    }

    // Prevent page-level scroll when keyboard is visible.
    // iOS Safari scrolls the document to bring xterm's hidden textarea into
    // view when the user types, pushing the entire UI off-screen. The CSS
    // position:fixed on .app prevents most cases, but reset as a safety net.
    this._windowScrollHandler = () => {
      if (this.keyboardVisible) {
        window.scrollTo(0, 0);
      }
    };
    window.addEventListener('scroll', this._windowScrollHandler);

    this._orientationHandler = () => this.handleOrientationChange();
    window.addEventListener('orientationchange', this._orientationHandler);
    try {
      screen.orientation?.addEventListener?.('change', this._orientationHandler);
    } catch {
      // Older iOS only supports window.orientationchange.
    }
  },

  /** Remove event listeners */
  cleanup() {
    if (this._focusinHandler) {
      document.removeEventListener('focusin', this._focusinHandler);
      this._focusinHandler = null;
    }
    if (this._touchInputHandler) {
      document.removeEventListener('touchstart', this._touchInputHandler, { capture: true });
      this._touchInputHandler = null;
    }
    if (this._viewportResizeHandler && window.visualViewport) {
      window.visualViewport.removeEventListener('resize', this._viewportResizeHandler);
      this._viewportResizeHandler = null;
    }
    if (this._viewportScrollHandler && window.visualViewport) {
      window.visualViewport.removeEventListener('scroll', this._viewportScrollHandler);
      this._viewportScrollHandler = null;
    }
    if (this._windowScrollHandler) {
      window.removeEventListener('scroll', this._windowScrollHandler);
      this._windowScrollHandler = null;
    }
    if (this._orientationHandler) {
      window.removeEventListener('orientationchange', this._orientationHandler);
      try {
        screen.orientation?.removeEventListener?.('change', this._orientationHandler);
      } catch {}
      this._orientationHandler = null;
    }
    for (const listener of this._nativeKeyboardListeners) {
      try {
        listener?.remove?.();
      } catch {}
    }
    this._nativeKeyboardListeners = [];
    for (const pending of this._nativeKeyboardListenerPromises) {
      pending
        .then((listener) => {
          try {
            listener?.remove?.();
          } catch {}
        })
        .catch(() => {});
    }
    this._nativeKeyboardListenerPromises = [];
    this._nativeKeyboardHeight = 0;
    document.documentElement.style.removeProperty('--native-keyboard-height');
    if (this._viewportSettleTimer) {
      clearTimeout(this._viewportSettleTimer);
      this._viewportSettleTimer = null;
    }
    this._settleRestoreScroll = false;
    this._settlePending = false;
    this._settleFollowing = true;
    this._settleAnchorY = null;
  },

  handleNativeKeyboardShow(info = {}) {
    const keyboardHeight = Math.max(0, Number(info.keyboardHeight) || 0);
    this._nativeKeyboardHeight = keyboardHeight;
    document.documentElement.style.setProperty('--native-keyboard-height', `${keyboardHeight}px`);
    if (!this.keyboardVisible) {
      this.keyboardVisible = true;
      document.body.classList.add('keyboard-visible');
      this.onKeyboardShow();
    }
    const viewportHeight = window.visualViewport?.height || window.innerHeight;
    if (keyboardHeight > 0) {
      const eventBasedHeight = Math.max(1, this.initialViewportHeight - keyboardHeight);
      this._setKeyboardAppHeight(Math.min(viewportHeight, eventBasedHeight));
      document.documentElement.style.setProperty('--app-top', '0px');
    }
    this.updateLayoutForKeyboard();
    this.scrollFocusedInputIntoView();
    this._deferViewportSettle();
  },

  handleNativeKeyboardHide() {
    this._nativeKeyboardHeight = 0;
    document.documentElement.style.removeProperty('--native-keyboard-height');
    if (this.keyboardVisible) {
      this.keyboardVisible = false;
      document.body.classList.remove('keyboard-visible');
      this.onKeyboardHide();
    }
    MobileDetection.updateAppHeight();
  },

  _keyboardOffsetForViewport() {
    const viewport = window.visualViewport;
    const layoutHeight = window.innerHeight;
    const visualBottom = (viewport?.offsetTop || 0) + (viewport?.height || layoutHeight);
    const viewportOffset = Math.max(0, layoutHeight - visualBottom);
    const viewportShrink = Math.max(0, this.initialViewportHeight - (viewport?.height || layoutHeight));
    const nativeOffset = viewportShrink > 100 ? 0 : this._nativeKeyboardHeight || 0;
    return Math.max(0, viewportOffset, nativeOffset);
  },

  _isNativeKeyboardLayout() {
    return (
      document.body.classList.contains('codeman-native') ||
      document.documentElement.classList.contains('codeman-native')
    );
  },

  _setKeyboardAppHeight(height) {
    const reserve = this._isNativeKeyboardLayout() ? 44 : 0;
    document.documentElement.style.setProperty('--app-height', `${Math.max(1, height - reserve)}px`);
  },

  handleOrientationChange() {
    const refresh = () => {
      if (!MobileDetection.isTouchDevice()) return;
      if (!this.keyboardVisible && this._hasKeyboardFocus()) {
        this.keyboardVisible = true;
        document.body.classList.add('keyboard-visible');
        this.onKeyboardShow();
      }
      if (!this.keyboardVisible) {
        this.initialViewportHeight = window.visualViewport?.height || window.innerHeight;
        MobileDetection.updateAppHeight();
        return;
      }

      const viewport = window.visualViewport;
      const layoutHeight = window.innerHeight;
      const visualHeight = viewport?.height || layoutHeight;
      const visualBottom = (viewport?.offsetTop || 0) + visualHeight;
      const viewportKeyboard = Math.max(0, layoutHeight - visualBottom);

      if (viewportKeyboard > 100) {
        this._nativeKeyboardHeight = 0;
        document.documentElement.style.removeProperty('--native-keyboard-height');
        this._setKeyboardAppHeight(visualHeight);
      } else if (this._nativeKeyboardHeight > 0) {
        const landscape = window.innerWidth > window.innerHeight;
        const expected = Math.round(layoutHeight * (landscape ? 0.45 : 0.38));
        const maxKeyboard = Math.round(layoutHeight * 0.55);
        this._nativeKeyboardHeight = Math.max(
          120,
          Math.min(maxKeyboard, Math.max(this._nativeKeyboardHeight, expected))
        );
        document.documentElement.style.setProperty('--native-keyboard-height', `${this._nativeKeyboardHeight}px`);
        this._setKeyboardAppHeight(Math.max(1, layoutHeight - this._nativeKeyboardHeight));
      } else {
        this._setKeyboardAppHeight(visualHeight);
      }

      document.documentElement.style.setProperty('--app-top', `${viewport?.offsetTop || 0}px`);
      this.updateLayoutForKeyboard();
      this.scrollFocusedInputIntoView();
      this._scheduleViewportSettle({ restoreScroll: true });
    };

    [80, 250, 600, 1000].forEach((delay) => setTimeout(refresh, delay));
  },

  /** Handle viewport resize (keyboard show/hide) */
  handleViewportResize() {
    const currentHeight = window.visualViewport?.height || window.innerHeight;
    const heightDiff = this.initialViewportHeight - currentHeight;
    const focusedKeyboardInput = this._hasKeyboardFocus();

    // Keyboard appeared (viewport shrunk by more than 150px)
    if (heightDiff > 150 && !this.keyboardVisible) {
      this.keyboardVisible = true;
      document.body.classList.add('keyboard-visible');
      // While the keyboard is open, size the app to the visual viewport so
      // xterm's bottom row and cursor sit above the OS keyboard.
      this._setKeyboardAppHeight(currentHeight);
      document.documentElement.style.setProperty('--app-top', `${window.visualViewport?.offsetTop || 0}px`);
      this.onKeyboardShow();
    }
    // Keyboard hidden (viewport grew back close to initial)
    // Use 100px threshold (not 50) to handle iOS address bar drift,
    // iOS 26's persistent 24px discrepancy, and Safari bottom bar changes
    else if (heightDiff < 100 && this.keyboardVisible && !focusedKeyboardInput && this._nativeKeyboardHeight <= 0) {
      this.keyboardVisible = false;
      document.body.classList.remove('keyboard-visible');
      this.onKeyboardHide();
      // Re-sync --app-height now that keyboard is gone (MobileDetection skipped
      // updates while keyboardVisible was true)
      MobileDetection.updateAppHeight();
    }

    // Update baseline when keyboard is not visible — adapts to address bar
    // state changes, orientation changes, and other viewport shifts
    if (!this.keyboardVisible) {
      this.initialViewportHeight = currentHeight;
    } else {
      this._setKeyboardAppHeight(currentHeight);
      document.documentElement.style.setProperty('--app-top', `${window.visualViewport?.offsetTop || 0}px`);
    }

    this.updateLayoutForKeyboard();
    this.scrollFocusedInputIntoView();
    this._deferViewportSettle();
    this.lastViewportHeight = currentHeight;
  },

  /** Update layout when keyboard shows/hides */
  updateLayoutForKeyboard() {
    if (!window.visualViewport) return;

    if (!MobileDetection.isTouchDevice()) {
      this.resetLayout();
      return;
    }

    const cjkInput = document.getElementById('cjkInput');
    const isHandheldLandscape = MobileDetection.isHandheldDevice?.() && window.innerHeight < 520;
    const isSmallMedium = MobileDetection.isSmallScreen() || MobileDetection.isMediumScreen() || isHandheldLandscape;

    if (this.keyboardVisible) {
      const keyboardHeight = this.initialViewportHeight - (window.visualViewport.height || window.innerHeight);
      const accessoryBar = document.querySelector('.keyboard-accessory-bar');

      if (isSmallMedium) {
        // Phones/small tablets: toolbar and accessory bar are position:fixed
        // via CSS. Use translateY to lift them above the keyboard.
        const toolbar = document.querySelector('.toolbar');
        const main = document.querySelector('.main');

        const keyboardOffset = this._keyboardOffsetForViewport();

        if (toolbar) {
          toolbar.style.transform = keyboardOffset > 0 ? `translateY(${-keyboardOffset}px)` : '';
        }
        if (accessoryBar) {
          accessoryBar.style.transform = keyboardOffset > 0 ? `translateY(${-keyboardOffset}px)` : '';
        }
        if (main) {
          const cjkInputHeight = cjkInput?.classList.contains('cjk-input-visible') ? 44 : 0;
          const baseChromeHeight = this._isNativeKeyboardLayout() ? 0 : 84;
          main.style.paddingBottom = `calc(${baseChromeHeight + cjkInputHeight}px + var(--safe-area-bottom))`;
        }
      } else if (keyboardHeight > 0) {
        // iPad: use direct bottom positioning (translateY unreliable —
        // iOS auto-scrolls the visual viewport, making keyboardOffset ≈ 0).
        if (accessoryBar) {
          accessoryBar.style.bottom = `${keyboardHeight}px`;
        }
      }

      // CJK textarea positioning (always position:fixed on touch devices).
      if (cjkInput?.classList.contains('cjk-input-visible') && keyboardHeight > 0) {
        if (isSmallMedium) {
          // Phones: use translateY like toolbar/accessory bar.
          const keyboardOffset = this._keyboardOffsetForViewport();
          cjkInput.style.transform = keyboardOffset > 0 ? `translateY(${-keyboardOffset}px)` : '';
          cjkInput.style.bottom = '';
        } else {
          // iPad: direct bottom = keyboard + accessory bar height.
          cjkInput.style.bottom = `${keyboardHeight + 44}px`;
          cjkInput.style.transform = '';
        }
      }
    } else {
      this.resetLayout();
    }
  },

  /** Reset layout to normal (no keyboard) */
  resetLayout() {
    const toolbar = document.querySelector('.toolbar');
    const accessoryBar = document.querySelector('.keyboard-accessory-bar');
    const cjkInput = document.getElementById('cjkInput');
    const main = document.querySelector('.main');

    if (toolbar) {
      toolbar.style.transform = '';
    }
    if (accessoryBar) {
      accessoryBar.style.transform = '';
      accessoryBar.style.bottom = '';
    }
    if (cjkInput) {
      cjkInput.style.transform = '';
      cjkInput.style.bottom = '';
    }
    if (main) {
      main.style.paddingBottom = '';
    }
  },

  /** Called when keyboard appears */
  onKeyboardShow() {
    // Show keyboard accessory bar
    if (typeof KeyboardAccessoryBar !== 'undefined') {
      KeyboardAccessoryBar.show();
    }

    // Reset any page scroll that occurred during keyboard open.
    // iOS Safari may scroll the document to reveal xterm's hidden textarea.
    window.scrollTo(0, 0);

    // visualViewport emits multiple heights throughout the OS animation.
    // Re-schedule on every event and fit only after the final height settles.
    this._scheduleViewportSettle({ restoreScroll: true });

    // Reposition subagent windows to stack from bottom (above keyboard)
    if (typeof app !== 'undefined') app.relayoutMobileSubagentWindows();
  },

  /** Called when keyboard hides */
  onKeyboardHide() {
    // Hide keyboard accessory bar
    if (typeof KeyboardAccessoryBar !== 'undefined') {
      KeyboardAccessoryBar.hide();
    }

    this.resetLayout();

    this._scheduleViewportSettle({ restoreScroll: true });

    // Reposition subagent windows to stack from top (below header)
    if (typeof app !== 'undefined') app.relayoutMobileSubagentWindows();
  },

  /**
   * Coalesce the keyboard animation into one final xterm reflow and PTY resize.
   * Only a real show/hide transition arms the settle work; ongoing viewport
   * resize events merely push a pending settle back (_deferViewportSettle).
   * A viewport change that never crosses the show/hide thresholds must not
   * refit: keyboard detection can miss a fine-grained OS animation entirely
   * (each step under 150px, with the baseline chasing the animation), and the
   * container is then mid-animation with no keyboard CSS compensation, so a
   * fit against it resizes the PTY to transient dims and the SIGWINCH thrash
   * garbles the transcript.
   */
  _scheduleViewportSettle({ restoreScroll = false } = {}) {
    // Capture scroll intent on the FIRST event of a settle cycle, BEFORE any
    // fit() has reflowed the buffer — a later capture reads an already-moved
    // viewportY. Issue #259: this path used to force scrollToBottom
    // unconditionally, so opening the keyboard yanked a user who was reading
    // history down to the live output.
    if (!this._settlePending) this._captureTerminalScrollIntent();
    this._settleRestoreScroll = this._settleRestoreScroll || restoreScroll;
    this._settlePending = true;
    this._armViewportSettleTimer();
  },

  /**
   * Record whether the terminal is following live output, and if not, the top
   * visible line to return to. `_settleFollowing` defaults to true so a
   * terminal we cannot read keeps the historical scroll-to-bottom behavior.
   */
  _captureTerminalScrollIntent() {
    this._settleFollowing = true;
    this._settleAnchorY = null;
    if (typeof app === 'undefined' || !app.terminal?.buffer?.active) return;
    this._settleFollowing = app.isTerminalAtBottom();
    if (!this._settleFollowing) this._settleAnchorY = app.terminal.buffer.active.viewportY;
  },

  /**
   * Return to the captured anchor after the keyboard reflow. Reflow can rewrap
   * lines, so the anchor is approximate by construction; it is clamped to the
   * post-reflow buffer rather than trusted blindly.
   */
  _restoreTerminalScrollIntent() {
    const term = typeof app !== 'undefined' ? app.terminal : null;
    const anchor = this._settleAnchorY;
    if (typeof anchor !== 'number' || typeof term?.scrollToLine !== 'function' || !term.buffer?.active) {
      term?.scrollToBottom?.();
      return;
    }
    term.scrollToLine(Math.max(0, Math.min(anchor, term.buffer.active.baseY)));
  },

  /** Push a pending settle back while the viewport is still animating; no-op otherwise. */
  _deferViewportSettle() {
    if (!this._settlePending) return;
    this._armViewportSettleTimer();
  },

  _armViewportSettleTimer() {
    if (this._viewportSettleTimer) clearTimeout(this._viewportSettleTimer);
    this._viewportSettleTimer = setTimeout(() => {
      this._viewportSettleTimer = null;
      this._settlePending = false;
      const shouldRestoreScroll = this._settleRestoreScroll;
      this._settleRestoreScroll = false;

      if (typeof app !== 'undefined' && app.terminal) {
        if (app.fitAddon) {
          try {
            app.fitAddon.fit();
          } catch {}
        }
        if (this.keyboardVisible) this._shrinkPaddingToFit();
        // Following live output → bottom, as before. Reading history → back to
        // the pre-reflow anchor instead of being yanked down (#259).
        if (shouldRestoreScroll) {
          if (this._settleFollowing === false) this._restoreTerminalScrollIntent();
          else app.terminal.scrollToBottom();
        }
        app._syncMobileHelperTextareaToCursor?.();
        app._localEchoOverlay?.rerender?.();
        this._sendTerminalResize();
      }
      window.scrollTo(0, 0);
    }, this.VIEWPORT_SETTLE_MS);
  },

  /** Send current terminal dimensions to the server (one-shot, for keyboard open/close) */
  _sendTerminalResize() {
    if (typeof app === 'undefined' || !app.activeSessionId || !app.fitAddon) return;
    try {
      const dims = app.fitAddon.proposeDimensions();
      if (dims) {
        const cols = Math.max(dims.cols, 40);
        const rows = Math.max(dims.rows, 10);
        app._lastResizeDims = { cols, rows };
        // Declare the viewport type so resize arbitration can ignore this
        // while a desktop connection is sizing the same session.
        const viewportType = MobileDetection.getDeviceType ? MobileDetection.getDeviceType() : 'mobile';
        fetch(`/api/sessions/${app.activeSessionId}/resize`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ cols, rows, viewportType }),
        }).catch(() => {});
      }
    } catch {}
  },

  /**
   * Shrink .main paddingBottom to eliminate the terminal row quantization gap.
   * xterm can only render whole rows, so fractional-row pixels create dead
   * space below the last row. After fitAddon.fit(), measure the gap and
   * reduce padding by that amount so the terminal sits flush against the bars.
   */
  _shrinkPaddingToFit() {
    try {
      const container = document.getElementById('terminalContainer');
      const main = document.querySelector('.main');
      if (!container || !main || typeof app === 'undefined' || !app.terminal) return;
      const cellH = app.terminal._core?._renderService?.dimensions?.css?.cell?.height;
      if (!cellH) return;
      const gap = container.clientHeight - app.terminal.rows * cellH;
      if (gap > 0 && gap < cellH) {
        const currentPadding = parseInt(main.style.paddingBottom) || 0;
        main.style.paddingBottom = Math.max(0, currentPadding - gap) + 'px';
        if (app.fitAddon)
          try {
            app.fitAddon.fit();
          } catch {}
      }
    } catch {}
  },

  /** Check if element is an input that triggers keyboard (excludes terminal) */
  isInputElement(el) {
    if (!el) return false;

    // Exclude xterm.js terminal inputs (they handle their own scroll)
    if (el.closest('.xterm') || el.closest('.terminal-container')) {
      return false;
    }

    const tagName = el.tagName?.toLowerCase();
    // Exclude type=range, type=checkbox, type=radio (don't trigger keyboard)
    if (tagName === 'input') {
      const type = el.type?.toLowerCase();
      if (type === 'checkbox' || type === 'radio' || type === 'range' || type === 'file') {
        return false;
      }
    }
    return tagName === 'input' || tagName === 'textarea' || el.isContentEditable;
  },

  _hasKeyboardFocus() {
    const el = document.activeElement;
    if (!el) return false;
    const tagName = el.tagName?.toLowerCase();
    if (tagName === 'input') {
      const type = el.type?.toLowerCase();
      return type !== 'checkbox' && type !== 'radio' && type !== 'range' && type !== 'file';
    }
    return tagName === 'textarea' || el.isContentEditable;
  },

  /** Scroll input into view above the keyboard */
  scheduleFocusedInputScroll(input = document.activeElement) {
    if (!this.isInputElement(input)) return;
    [0, 80, 220, 420, 700, 950].forEach((delay) => {
      setTimeout(() => this.scrollInputIntoView(input), delay);
    });
  },

  scrollFocusedInputIntoView() {
    const input = document.activeElement;
    if (!this.isInputElement(input)) return;
    this.scrollInputIntoView(input);
  },

  scrollInputIntoView(input) {
    // Check if input is still focused (user might have tapped away)
    if (document.activeElement !== input) return;

    const scroller = this.getInputScrollContainer(input);
    const visualBottom = this.getUsableVisualBottom(input, scroller);
    const visualTop = window.visualViewport?.offsetTop || 0;
    const inputRect = input.getBoundingClientRect();
    const margin = 36;
    const behavior = this.keyboardVisible ? 'auto' : 'smooth';

    if (scroller) {
      let delta = 0;
      const scrollerTop = Math.max(visualTop, scroller.getBoundingClientRect().top);
      const safeHeight = Math.max(80, visualBottom - scrollerTop);
      const preferredBottom = this.keyboardVisible ? scrollerTop + safeHeight * 0.72 : visualBottom - margin;
      if (inputRect.bottom + margin > preferredBottom) {
        delta = inputRect.bottom + margin - preferredBottom;
      } else if (inputRect.top - margin < scrollerTop) {
        delta = inputRect.top - margin - scrollerTop;
      }
      if (Math.abs(delta) > 1) {
        scroller.scrollBy({ top: delta, behavior });
      }
      return;
    }

    if (inputRect.bottom + margin > visualBottom || inputRect.top < visualTop) {
      input.scrollIntoView({ block: 'center', behavior });
    }
  },

  getInputScrollContainer(input) {
    const modal = input.closest('.modal.active');
    if (modal) {
      return input.closest('.set-doc, .modal-body') || modal.querySelector('.set-doc, .modal-body') || null;
    }

    const scrollable = input.closest('.set-doc, .modal-body, .main, .panel-content');
    if (scrollable && scrollable.scrollHeight > scrollable.clientHeight) return scrollable;
    return null;
  },

  getUsableVisualBottom(input, scroller) {
    const viewport = window.visualViewport;
    let bottom = viewport ? viewport.offsetTop + viewport.height : window.innerHeight;
    const modal = input.closest('.modal.active');
    const footer = modal?.querySelector('.set-foot, .form-actions, .modal-footer');
    if (footer) {
      const footerRect = footer.getBoundingClientRect();
      if (footerRect.height > 0) bottom = Math.min(bottom, footerRect.top);
    }
    const blockingElements = document.querySelectorAll('.keyboard-accessory-bar.visible, .toolbar');
    blockingElements.forEach((el) => {
      const rect = el.getBoundingClientRect();
      if (rect.height > 0 && rect.top > 0 && rect.top < bottom) bottom = rect.top;
    });
    if (scroller) {
      const scrollRect = scroller.getBoundingClientRect();
      bottom = Math.min(bottom, scrollRect.bottom);
    }
    return bottom - 12;
  },
};

// ═══════════════════════════════════════════════════════════════
// Mobile Swipe Handler
// ═══════════════════════════════════════════════════════════════

/**
 * SwipeHandler - Detects horizontal swipes on terminal to switch sessions.
 * Only active on mobile/touch devices.
 */
const SwipeHandler = {
  startX: 0,
  startY: 0,
  startTime: 0,
  minSwipeDistance: 80, // Minimum pixels for a valid swipe
  maxSwipeTime: 300, // Maximum ms for a swipe gesture
  maxVerticalDrift: 100, // Max vertical movement allowed

  _touchStartHandler: null,
  _touchEndHandler: null,
  _element: null,
  _ignoreGesture: false,

  /** Initialize swipe handling */
  init() {
    // Only on touch devices
    if (!MobileDetection.isTouchDevice()) return;

    const terminal = document.querySelector('.main');
    if (!terminal) return;

    this._element = terminal;
    this._touchStartHandler = (e) => this.onTouchStart(e);
    this._touchEndHandler = (e) => this.onTouchEnd(e);
    terminal.addEventListener('touchstart', this._touchStartHandler, { passive: true });
    terminal.addEventListener('touchend', this._touchEndHandler, { passive: true });
  },

  /** Remove swipe listeners */
  cleanup() {
    if (this._element && this._touchStartHandler) {
      this._element.removeEventListener('touchstart', this._touchStartHandler);
      this._element.removeEventListener('touchend', this._touchEndHandler);
    }
    this._touchStartHandler = null;
    this._touchEndHandler = null;
    this._element = null;
  },

  onTouchStart(e) {
    // The session sidebar is an overlay child of .main, so its touches bubble in
    // here. Swiping across the open session drawer — the natural "dismiss it"
    // gesture — would otherwise fire nextSession() and drop the user into a
    // session they never tapped.
    this._ignoreGesture = !!e.target?.closest?.('.session-sidebar');
    if (this._ignoreGesture) return;
    if (!e.touches || e.touches.length !== 1) return;
    this.startX = e.touches[0].clientX;
    this.startY = e.touches[0].clientY;
    this.startTime = Date.now();
  },

  onTouchEnd(e) {
    if (this._ignoreGesture) {
      this._ignoreGesture = false;
      return;
    }
    if (!e.changedTouches || e.changedTouches.length !== 1) return;

    const endX = e.changedTouches[0].clientX;
    const endY = e.changedTouches[0].clientY;
    const elapsed = Date.now() - this.startTime;

    // Check if it's a valid swipe
    const deltaX = endX - this.startX;
    const deltaY = Math.abs(endY - this.startY);

    if (elapsed > this.maxSwipeTime) return; // Too slow
    if (deltaY > this.maxVerticalDrift) return; // Too much vertical movement
    if (Math.abs(deltaX) < this.minSwipeDistance) return; // Too short

    // Valid swipe detected
    if (deltaX > 0) {
      // Swipe right -> previous session
      if (typeof app !== 'undefined') app.prevSession();
    } else {
      // Swipe left -> next session
      if (typeof app !== 'undefined') app.nextSession();
    }
  },
};
