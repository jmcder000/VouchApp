// analyzer-server/server.mjs
import express from "express";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();

// Increase JSON limit to handle base64 screenshots comfortably
app.use(express.json({ limit: "25mb" }));

// Ensure screenshots directory exists
const shotsDir = path.join(__dirname, "screenshots");
fs.mkdirSync(shotsDir, { recursive: true });

app.get("/healthz", (_req, res) => {
  res.status(200).send("ok");
});

// Helper: safe filenames
function safe(s) {
  return String(s || "")
    .replaceAll(/[^\w.\-]+/g, "_")
    .slice(0, 64);
}

app.post("/analyze", (req, res) => {
  try {
    const p = req.body; // AnalysisPayload
    if (!p || typeof p !== "object") {
      return res.status(400).json({ ok: false, error: "Bad payload" });
    }

    // Print summary to console
    const ts = p.timestamp || new Date().toISOString();
    const appName = p.app?.name || "App";
    const bundleId = p.app?.bundleId || "";
    const winTitle = p.window?.title || "";
    const text = p.typedTextChunk || "";

    console.log("—".repeat(60));
    console.log(`[${ts}] ${appName}${bundleId ? " (" + bundleId + ")" : ""}`);
    if (winTitle) console.log(`Window: ${winTitle}`);
    console.log(`Text (${text.length} chars):`);
    console.log(text.length > 240 ? text.slice(0, 240) + " …" : text);

    // Save screenshot if present
    let savedPath = null;
    if (p.screenshot?.dataBase64 && p.screenshot?.mime) {
      const buf = Buffer.from(p.screenshot.dataBase64, "base64");
      const ext = p.screenshot.mime === "image/png" ? ".png" : ".jpg";
      const stamp = ts.replaceAll(/[:.]/g, "-");
      const file = `${stamp}_${safe(appName)}_${safe(p.window?.id)}${ext}`;
      const outPath = path.join(shotsDir, file);
      fs.writeFileSync(outPath, buf);
      savedPath = outPath;
      console.log(`Saved screenshot → ${outPath} (${buf.length} bytes)`);
    } else {
      console.log("No screenshot in payload.");
    }

    return res.status(200).json({ ok: true, savedScreenshotPath: savedPath });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ ok: false, error: String(err) });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Analyzer server listening on http://127.0.0.1:${PORT}`);
  console.log(`Screenshots will be saved under: ${shotsDir}`);
});
