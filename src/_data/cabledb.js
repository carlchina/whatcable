// Loads the generated cable dataset for the /cables page.
//
// The list comes from docs/cables.json (written by
// scripts/build-cable-db.swift, which runs before Eleventy in
// scripts/build-site.sh). The "updated" timestamp comes from the
// mtime of data/known-cables.md so the visible date reflects when
// the human-curated source was last edited, not when Eleventy ran.
//
// If either file is missing (e.g. someone runs `bun run site:build`
// standalone on a fresh checkout before the Swift step), we fall
// back to an empty list and today's date so the build still
// succeeds instead of blowing up.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");
const cablesPath = path.join(repoRoot, "docs", "cables.json");
const sourcePath = path.join(repoRoot, "data", "known-cables.md");

function readList() {
  try {
    return JSON.parse(fs.readFileSync(cablesPath, "utf8"));
  } catch {
    return [];
  }
}

function readUpdated() {
  try {
    return fs.statSync(sourcePath).mtime;
  } catch {
    return new Date();
  }
}

const list = readList();

export default {
  list,
  count: list.length,
  updated: readUpdated(),
  // Pre-built ItemList entries for JSON-LD. Each item links back to
  // the GitHub issue (canonical source) until per-cable pages exist.
  itemList: list.map((c, i) => ({
    "@type": "ListItem",
    position: i + 1,
    item: {
      "@type": "Product",
      name: String(c.brand || "").split(";")[0].trim(),
      identifier: c.issueNum,
      url: c.issueURL,
      brand: c.vendor || undefined,
      additionalProperty: [
        c.vid && { "@type": "PropertyValue", name: "USB-IF VID", value: c.vid },
        c.pid && { "@type": "PropertyValue", name: "USB-IF PID", value: c.pid },
        c.speed && { "@type": "PropertyValue", name: "Speed", value: c.speed },
        c.power && { "@type": "PropertyValue", name: "Power", value: c.power },
        c.type && { "@type": "PropertyValue", name: "Cable type", value: c.type },
      ].filter(Boolean),
    },
  })),
};
