import {mountShipyardRenderer} from "/renderer.js";

const standaloneMounts = new WeakMap();
const WINDOWS = new Set(["24h", "7d", "30d"]);

export function createStandaloneAdapter(view = window) {
  const controllers = new Set();
  let tornDown = false;

  async function fetchJson(path) {
    if (tornDown) throw new Error("Standalone dashboard adapter is torn down");
    const url = new URL(path, view.location.href);
    if (url.origin !== view.location.origin) throw new Error("Cross-origin dashboard request blocked");
    const controller = new view.AbortController();
    controllers.add(controller);
    try {
      const response = await view.fetch(url.pathname + url.search, {
        headers: {Accept: "application/json"},
        signal: controller.signal,
      });
      if (!response.ok) throw new Error(`Local API returned ${response.status}`);
      return response.json();
    } finally {
      controllers.delete(controller);
    }
  }

  const routeWindow = new URL(view.location.href).searchParams.get("window");
  return {
    initialWindow: WINDOWS.has(routeWindow) ? routeWindow : "7d",
    hostProvenance: null,
    fetchOperator: windowValue => fetchJson(`/api/operator?window=${encodeURIComponent(windowValue)}`),
    fetchEvents: (windowValue, limit) => fetchJson(`/api/events?window=${encodeURIComponent(windowValue)}&limit=${encodeURIComponent(limit)}`),
    subscribe({onOpen, onUpdate, onError}) {
      if (tornDown) throw new Error("Standalone dashboard adapter is torn down");
      const source = new view.EventSource("/api/stream");
      source.addEventListener("open", onOpen);
      source.addEventListener("shipyard", onUpdate);
      source.addEventListener("error", onError);
      return () => {
        source.removeEventListener("open", onOpen);
        source.removeEventListener("shipyard", onUpdate);
        source.removeEventListener("error", onError);
        source.close();
      };
    },
    updateRoute(windowValue) {
      if (!WINDOWS.has(windowValue)) return;
      const url = new URL(view.location.href);
      url.searchParams.set("window", windowValue);
      view.history.pushState({shipyardWindow: windowValue}, "", url);
    },
    subscribeRoute(onWindow) {
      const listener = () => {
        const value = new URL(view.location.href).searchParams.get("window");
        onWindow(WINDOWS.has(value) ? value : "7d");
      };
      view.addEventListener("popstate", listener);
      return () => view.removeEventListener("popstate", listener);
    },
    teardown() {
      tornDown = true;
      for (const controller of controllers) controller.abort();
      controllers.clear();
    },
  };
}

export function bootstrapStandaloneDashboard(root, view = window) {
  standaloneMounts.get(root)?.();
  const adapter = createStandaloneAdapter(view);
  const unmountRenderer = mountShipyardRenderer(root, adapter);
  let mounted = true;
  const teardown = () => {
    if (!mounted) return;
    mounted = false;
    view.removeEventListener("pagehide", teardown);
    unmountRenderer();
    if (standaloneMounts.get(root) === teardown) standaloneMounts.delete(root);
  };
  standaloneMounts.set(root, teardown);
  view.addEventListener("pagehide", teardown, {once: true});
  return teardown;
}

const root = document.getElementById("shipyard-renderer-root");
if (root) bootstrapStandaloneDashboard(root);
