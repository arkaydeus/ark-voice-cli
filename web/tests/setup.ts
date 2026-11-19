import { afterEach } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";

GlobalRegistrator.register();

// DOM tests exercise dialog behavior without CSS animations or a layout engine.
Object.assign(globalThis, { BASE_UI_ANIMATIONS_DISABLED: true });

// Import after the DOM exists: Testing Library binds `screen` at import time.
const { cleanup } = await import("@testing-library/react");
afterEach(cleanup);
