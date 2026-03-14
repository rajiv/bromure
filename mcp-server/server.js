#!/usr/bin/env node

/**
 * Bromure MCP Server
 *
 * Exposes Bromure's sandboxed browser automation to Claude Code and other
 * MCP-compatible AI tools.  Talks to the Bromure automation API (HTTP) for
 * session lifecycle and uses Puppeteer-core over CDP for browser control.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import puppeteer from "puppeteer-core";

const BROMURE_API =
  process.env.BROMURE_API_URL || "http://127.0.0.1:9222";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function apiCall(method, path, body) {
  const opts = {
    method,
    headers: { "Content-Type": "application/json" },
  };
  if (body) opts.body = JSON.stringify(body);
  const res = await fetch(`${BROMURE_API}${path}`, opts);
  return res.json();
}

/** Map of sessionId → Puppeteer Browser instance. */
const browsers = new Map();

/** Map of sessionId → webSocketDebuggerUrl. */
const wsEndpoints = new Map();

/** Sleep helper. */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Connect Puppeteer to a session's CDP endpoint, with retries. */
async function connectBrowser(sessionId, retries = 3) {
  // If we already have a connected browser, verify it's still alive
  const existing = browsers.get(sessionId);
  if (existing) {
    try {
      await existing.pages(); // quick health check
      return existing;
    } catch {
      // Dead connection — discard and reconnect
      browsers.delete(sessionId);
    }
  }

  let wsUrl = wsEndpoints.get(sessionId);
  if (!wsUrl) {
    const info = await apiCall("GET", `/sessions/${sessionId}`);
    if (info.error) throw new Error(`Session ${sessionId}: ${info.error}`);
    wsUrl = info.webSocketDebuggerUrl;
    if (!wsUrl) throw new Error(`Session ${sessionId}: no webSocketDebuggerUrl`);
    wsEndpoints.set(sessionId, wsUrl);
  }

  let lastErr;
  for (let i = 0; i < retries; i++) {
    try {
      const browser = await puppeteer.connect({ browserWSEndpoint: wsUrl });
      browsers.set(sessionId, browser);
      // Clean up on unexpected disconnect
      browser.on("disconnected", () => browsers.delete(sessionId));
      return browser;
    } catch (e) {
      lastErr = e;
      if (i < retries - 1) await sleep(1000);
    }
  }
  throw new Error(`Failed to connect to CDP after ${retries} attempts: ${lastErr?.message || lastErr}`);
}

/** Get the active page for a session. */
async function getPage(sessionId) {
  const browser = await connectBrowser(sessionId);
  const pages = await browser.pages();
  return pages.find((p) => !p.url().startsWith("about:")) || pages[0];
}

function disconnectBrowser(sessionId) {
  const browser = browsers.get(sessionId);
  if (browser) {
    try { browser.disconnect(); } catch {}
    browsers.delete(sessionId);
  }
}

/** Wrap a tool handler with error handling that returns readable messages. */
function safeHandler(fn) {
  return async (args) => {
    try {
      return await fn(args);
    } catch (e) {
      const msg = e?.message || String(e);
      return {
        content: [{ type: "text", text: `Error: ${msg}` }],
        isError: true,
      };
    }
  };
}

/** Return a successful text response. */
function textResult(text) {
  return { content: [{ type: "text", text }] };
}

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

const server = new McpServer({
  name: "bromure",
  version: "1.0.0",
});

// -- Profiles ---------------------------------------------------------------

server.tool(
  "bromure_list_profiles",
  "List all available Bromure browser profiles. Each profile has its own settings (privacy, VPN, proxy, etc).",
  {},
  safeHandler(async () => {
    const data = await apiCall("GET", "/profiles");
    return textResult(JSON.stringify(data.profiles || data, null, 2));
  })
);

// -- Sessions ---------------------------------------------------------------

server.tool(
  "bromure_list_sessions",
  "List all active browser sessions with their IDs, profile names, and CDP endpoints.",
  {},
  safeHandler(async () => {
    const data = await apiCall("GET", "/sessions");
    return textResult(JSON.stringify(data.sessions || data, null, 2));
  })
);

server.tool(
  "bromure_open_session",
  "Open a new sandboxed browser session. Blocks until the page is fully loaded and ready for interaction. Returns the session ID needed for all other commands.",
  {
    profile: z
      .string()
      .describe("Profile name (e.g. 'Private Browsing', 'Twitter')"),
    url: z
      .string()
      .optional()
      .describe("Initial URL to navigate to (default: profile home page)"),
  },
  safeHandler(async ({ profile, url }) => {
    const body = { profile };
    if (url) body.url = url;
    const data = await apiCall("POST", "/sessions", body);
    if (data.error) throw new Error(data.error);

    // Cache WS endpoint and connect Puppeteer
    if (data.webSocketDebuggerUrl) {
      wsEndpoints.set(data.id, data.webSocketDebuggerUrl);
    }
    await connectBrowser(data.id);

    // Wait for the page to be fully loaded before returning
    const page = await getPage(data.id);
    try {
      await page.waitForNetworkIdle({ idleTime: 500, timeout: 15000 });
    } catch {
      // Timeout is fine — page may have long-polling connections
    }

    const title = await page.title();
    return textResult(`Session ${data.id} ready — ${page.url()} "${title}"`);
  })
);

server.tool(
  "bromure_close_session",
  "Close and destroy a browser session. The VM is shut down and all session data is discarded (unless using a persistent profile).",
  {
    sessionId: z.string().describe("Session ID to close"),
  },
  safeHandler(async ({ sessionId }) => {
    disconnectBrowser(sessionId);
    wsEndpoints.delete(sessionId);
    const data = await apiCall("DELETE", `/sessions/${sessionId}`);
    return textResult(JSON.stringify(data, null, 2));
  })
);

// -- Compound tools (single-call workflows) ---------------------------------

server.tool(
  "bromure_search",
  "Search Google in a sandboxed browser and return the results. Opens a session, searches, extracts results, and closes — all in one call. Use this for quick web lookups.",
  {
    query: z.string().describe("Search query"),
    profile: z
      .string()
      .optional()
      .describe("Profile name (default: 'Private Browsing')"),
  },
  safeHandler(async ({ query, profile }) => {
    const profileName = profile || "Private Browsing";
    const data = await apiCall("POST", "/sessions", {
      profile: profileName,
      url: `https://www.google.com/search?q=${encodeURIComponent(query)}`,
    });
    if (data.error) throw new Error(data.error);

    if (data.webSocketDebuggerUrl) {
      wsEndpoints.set(data.id, data.webSocketDebuggerUrl);
    }
    await connectBrowser(data.id);
    const page = await getPage(data.id);

    // Wait for search results
    try {
      await page.waitForSelector("#search", { timeout: 15000 });
    } catch {
      // Might be an AI overview or different layout
    }
    // Let the page settle
    await sleep(500);

    const content = await page.evaluate(() => {
      const el = document.querySelector("#search") || document.body;
      return el.innerText.substring(0, 8000);
    });

    // Close session
    disconnectBrowser(data.id);
    wsEndpoints.delete(data.id);
    await apiCall("DELETE", `/sessions/${data.id}`);

    return textResult(content);
  })
);

server.tool(
  "bromure_get_page",
  "Fetch a web page in a sandboxed browser and return its text content. Opens a session, loads the URL, extracts content, and closes — all in one call. Use this to read articles, documentation, etc.",
  {
    url: z.string().describe("URL to fetch"),
    profile: z
      .string()
      .optional()
      .describe("Profile name (default: 'Private Browsing')"),
    selector: z
      .string()
      .optional()
      .describe("CSS selector to extract (default: body)"),
  },
  safeHandler(async ({ url, profile, selector }) => {
    const profileName = profile || "Private Browsing";
    const data = await apiCall("POST", "/sessions", {
      profile: profileName,
      url,
    });
    if (data.error) throw new Error(data.error);

    if (data.webSocketDebuggerUrl) {
      wsEndpoints.set(data.id, data.webSocketDebuggerUrl);
    }
    await connectBrowser(data.id);
    const page = await getPage(data.id);

    // Wait for network to settle (works even if page already loaded)
    try {
      await page.waitForNetworkIdle({ idleTime: 500, timeout: 15000 });
    } catch {
      // Timeout is fine — page may have long-polling connections
    }

    const sel = selector || "body";
    let content = await page.$eval(sel, (el) => el.innerText);
    if (content.length > 100000) {
      content = content.slice(0, 100000) + "\n\n[... truncated]";
    }

    // Close session
    disconnectBrowser(data.id);
    wsEndpoints.delete(data.id);
    await apiCall("DELETE", `/sessions/${data.id}`);

    return textResult(content);
  })
);

// -- Navigation -------------------------------------------------------------

server.tool(
  "bromure_navigate",
  "Navigate the browser to a URL. Waits for the page to finish loading.",
  {
    sessionId: z.string().describe("Session ID"),
    url: z.string().describe("URL to navigate to"),
    waitUntil: z
      .enum(["load", "domcontentloaded", "networkidle0", "networkidle2"])
      .optional()
      .describe("When to consider navigation complete (default: load)"),
  },
  safeHandler(async ({ sessionId, url, waitUntil }) => {
    const page = await getPage(sessionId);
    await page.goto(url, {
      waitUntil: waitUntil || "load",
      timeout: 30000,
    });
    return textResult(`Navigated to ${page.url()} — title: "${await page.title()}"`);
  })
);

// -- Screenshot -------------------------------------------------------------

server.tool(
  "bromure_screenshot",
  "Take a screenshot of the current page. Returns the image as base64-encoded PNG.",
  {
    sessionId: z.string().describe("Session ID"),
    fullPage: z
      .boolean()
      .optional()
      .describe("Capture the full scrollable page (default: false, viewport only)"),
    selector: z
      .string()
      .optional()
      .describe("CSS selector of a specific element to screenshot"),
  },
  safeHandler(async ({ sessionId, fullPage, selector }) => {
    const page = await getPage(sessionId);
    let buf;
    if (selector) {
      const el = await page.$(selector);
      if (!el) throw new Error(`Element not found: ${selector}`);
      buf = await el.screenshot({ type: "png" });
    } else {
      buf = await page.screenshot({
        type: "png",
        fullPage: fullPage || false,
      });
    }
    return {
      content: [
        {
          type: "image",
          data: buf.toString("base64"),
          mimeType: "image/png",
        },
      ],
    };
  })
);

// -- Click ------------------------------------------------------------------

server.tool(
  "bromure_click",
  "Click an element on the page by CSS selector.",
  {
    sessionId: z.string().describe("Session ID"),
    selector: z.string().describe("CSS selector of the element to click"),
  },
  safeHandler(async ({ sessionId, selector }) => {
    const page = await getPage(sessionId);
    await page.click(selector);
    return textResult(`Clicked: ${selector}`);
  })
);

// -- Type -------------------------------------------------------------------

server.tool(
  "bromure_type",
  "Type text into an input element. Optionally clear the field first.",
  {
    sessionId: z.string().describe("Session ID"),
    selector: z
      .string()
      .describe("CSS selector of the input element"),
    text: z.string().describe("Text to type"),
    clear: z
      .boolean()
      .optional()
      .describe("Clear the field before typing (default: false)"),
    pressEnter: z
      .boolean()
      .optional()
      .describe("Press Enter after typing (default: false)"),
  },
  safeHandler(async ({ sessionId, selector, text, clear, pressEnter }) => {
    const page = await getPage(sessionId);
    if (clear) {
      await page.click(selector, { clickCount: 3 });
    }
    await page.type(selector, text);
    if (pressEnter) {
      await page.keyboard.press("Enter");
    }
    return textResult(`Typed into ${selector}`);
  })
);

// -- Evaluate JS ------------------------------------------------------------

server.tool(
  "bromure_evaluate",
  "Execute JavaScript in the page and return the result. The expression should return a serializable value.",
  {
    sessionId: z.string().describe("Session ID"),
    expression: z
      .string()
      .describe(
        "JavaScript expression to evaluate (e.g. 'document.title', 'document.querySelectorAll(\"a\").length')"
      ),
  },
  safeHandler(async ({ sessionId, expression }) => {
    const page = await getPage(sessionId);
    const result = await page.evaluate(expression);
    return textResult(
      typeof result === "string"
        ? result
        : JSON.stringify(result, null, 2)
    );
  })
);

// -- Get Content ------------------------------------------------------------

server.tool(
  "bromure_get_content",
  "Get the text content or HTML of the page or a specific element.",
  {
    sessionId: z.string().describe("Session ID"),
    selector: z
      .string()
      .optional()
      .describe(
        "CSS selector (default: body). Use 'html' for full page HTML."
      ),
    format: z
      .enum(["text", "html"])
      .optional()
      .describe("Return text content or raw HTML (default: text)"),
  },
  safeHandler(async ({ sessionId, selector, format }) => {
    const page = await getPage(sessionId);
    const sel = selector || "body";
    const fmt = format || "text";

    let content;
    if (fmt === "html") {
      content = await page.$eval(sel, (el) => el.outerHTML);
    } else {
      content = await page.$eval(sel, (el) => el.innerText);
    }

    // Truncate very long content
    if (content.length > 100000) {
      content = content.slice(0, 100000) + "\n\n[... truncated]";
    }

    return textResult(content);
  })
);

// -- Get Links --------------------------------------------------------------

server.tool(
  "bromure_get_links",
  "Extract all links from the page with their text and URLs.",
  {
    sessionId: z.string().describe("Session ID"),
    selector: z
      .string()
      .optional()
      .describe("Scope to links within this CSS selector (default: entire page)"),
  },
  safeHandler(async ({ sessionId, selector }) => {
    const page = await getPage(sessionId);
    const scope = selector || "body";
    const links = await page.$eval(scope, (el) => {
      return Array.from(el.querySelectorAll("a[href]")).map((a) => ({
        text: a.innerText.trim().slice(0, 200),
        href: a.href,
      }));
    });
    return textResult(JSON.stringify(links, null, 2));
  })
);

// -- Wait For ---------------------------------------------------------------

server.tool(
  "bromure_wait_for",
  "Wait for an element matching the CSS selector to appear on the page.",
  {
    sessionId: z.string().describe("Session ID"),
    selector: z.string().describe("CSS selector to wait for"),
    timeout: z
      .number()
      .optional()
      .describe("Maximum wait time in milliseconds (default: 10000)"),
  },
  safeHandler(async ({ sessionId, selector, timeout }) => {
    const page = await getPage(sessionId);
    await page.waitForSelector(selector, {
      timeout: timeout || 10000,
    });
    return textResult(`Found: ${selector}`);
  })
);

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const transport = new StdioServerTransport();
await server.connect(transport);
