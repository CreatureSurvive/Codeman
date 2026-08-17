(function () {
  const cap = window.Capacitor;
  if (!cap || window.CodemanNative) return;

  document.documentElement.classList.add('codeman-native');

  const plugins = cap.Plugins || {};
  const tryCall = (pluginName, methodName, args) => {
    try {
      const result = plugins[pluginName]?.[methodName]?.(args || {});
      if (result && typeof result.catch === 'function') result.catch(() => {});
    } catch {
      // Native shell conveniences must not block the hosted web app.
    }
  };
  const call = async (name, method, args) => {
    const plugin = plugins[name];
    if (!plugin || typeof plugin[method] !== 'function') {
      throw new Error(`${name}.${method} is not available`);
    }
    return plugin[method](args || {});
  };

  window.CodemanNative = {
    isNative: true,
    platform: cap.getPlatform ? cap.getPlatform() : 'native',
    pickImages: async (options) => {
      if (typeof plugins.Camera?.pickImages === 'function') {
        return call('Camera', 'pickImages', {
          quality: 90,
          limit: 20,
          ...options,
        });
      }
      const photo = await call('Camera', 'getPhoto', {
        quality: 90,
        resultType: 'base64',
        source: 'PHOTOS',
        ...options,
      });
      return { photos: photo ? [photo] : [] };
    },
    pickImage: (options) =>
      call('Camera', 'getPhoto', {
        quality: 90,
        resultType: 'base64',
        source: 'PHOTOS',
        ...options,
      }),
    captureImage: (options) =>
      call('Camera', 'getPhoto', {
        quality: 90,
        resultType: 'base64',
        source: 'CAMERA',
        ...options,
      }),
    share: (options) => call('Share', 'share', options),
    notify: (title, body, extra) =>
      call('LocalNotifications', 'schedule', {
        notifications: [
          {
            id: Date.now() % 2147483647,
            title,
            body,
            extra,
            schedule: { at: new Date(Date.now() + 100) },
          },
        ],
      }),
    requestNotificationPermissions: () => call('LocalNotifications', 'requestPermissions'),
    registerPush: async () => {
      await call('PushNotifications', 'requestPermissions');
      return call('PushNotifications', 'register');
    },
    openExternal: (url) => call('Browser', 'open', { url }),
    vibrateSelection: () => call('Haptics', 'selectionChanged'),
    biometricUnlock: async () => ({ available: false, unlocked: true }),
  };

  if (document.body) {
    document.body.classList.add('codeman-native');
  }

  tryCall('StatusBar', 'setOverlaysWebView', { overlay: false });
  tryCall('StatusBar', 'setBackgroundColor', { color: '#0b0f17' });
  tryCall('Keyboard', 'setResizeMode', { mode: 'body' });

  const applyNativeBodyClass = () => document.body?.classList.add('codeman-native');
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', applyNativeBodyClass, { once: true });
  } else {
    applyNativeBodyClass();
  }

  window.dispatchEvent(new CustomEvent('codeman-native-ready', { detail: window.CodemanNative }));
})();
