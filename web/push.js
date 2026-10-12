

window.matchPush = (function () {
  let swRegistration = null;

  function urlBase64ToUint8Array(base64String) {
    const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
    const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
    const rawData = window.atob(base64);
    const outputArray = new Uint8Array(rawData.length);
    for (let i = 0; i < rawData.length; ++i) {
      outputArray[i] = rawData.charCodeAt(i);
    }
    return outputArray;
  }

  async function ensureRegistered() {
    if (!swRegistration) {
      swRegistration = await navigator.serviceWorker.register(
        new URL('custom-sw.js', document.baseURI),
      );
      await navigator.serviceWorker.ready;
    }
    return swRegistration;
  }

  async function isSupported() {
    return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window && !needsIosInstall();
  }

  function isIos() {
    return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
      (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  }

  function needsIosInstall() {
    const standalone = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
    return isIos() && !standalone;
  }

  async function subscriptionState() {
    if (needsIosInstall()) return 'ios-install-required';
    if (!(await isSupported())) return 'unsupported';
    await ensureRegistered();
    const sub = await swRegistration.pushManager.getSubscription();
    return sub ? 'subscribed' : 'unsubscribed';
  }

  async function subscribe(vapidPublicKey, teamNumber, eventKey, backendBase) {
    if (needsIosInstall()) return 'ios-install-required';
    if (!(await isSupported())) return 'unsupported';
    if (Notification.permission === 'denied') return 'permission-denied';
    try {
      await ensureRegistered();
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') return 'permission-denied';

    const configResponse = await fetch(`${backendBase}/push/config`);
    if (!configResponse.ok) return 'server-not-configured';
    const config = await configResponse.json();
    vapidPublicKey = config.vapidPublicKey;
    if (!vapidPublicKey) return 'server-not-configured';
    let sub = await swRegistration.pushManager.getSubscription();
    if (!sub) {
      sub = await swRegistration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(vapidPublicKey),
      });
    }
    const res = await fetch(`${backendBase}/push/subscribe`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        teamNumber,
        eventKey,
        subscription: sub.toJSON(),
        platform: isIos() ? 'ios' : 'web',
      }),
    });
    return res.ok ? 'subscribed' : 'server-rejected';
    } catch (error) {
      console.warn('Push subscription failed:', error);
      return 'subscription-failed';
    }
  }

  async function unsubscribe(backendBase) {
    await ensureRegistered();
    const sub = await swRegistration.pushManager.getSubscription();
    if (!sub) return true;
    try {
      await fetch(`${backendBase}/push/unsubscribe`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ endpoint: sub.endpoint }),
      });
    } catch (e) {
    }
    await sub.unsubscribe();
    return true;
  }

  return { isSupported, subscriptionState, subscribe, unsubscribe };
})();