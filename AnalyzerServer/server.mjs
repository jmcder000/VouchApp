// analyzer-server/server.mjs
import 'dotenv/config';
import express from "express";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { Metorial } from "metorial";
import OpenAI from "openai";
import { performance } from "node:perf_hooks";
import { z } from "zod";
import { zodResponseFormat } from "openai/helpers/zod.mjs";


const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
app.use(express.json({ limit: "25mb" }));

const shotsDir = path.join(__dirname, "screenshots");
fs.mkdirSync(shotsDir, { recursive: true });

const PORT = process.env.PORT || 3000;

const seenRequests = new Map(); // id -> timestamp(ms)
const DEDUPE_TTL_MS = 60_000;
function isDuplicate(id) {
  if (!id) return false;
  const now = Date.now();
  const t = seenRequests.get(id);
  if (t && now - t < DEDUPE_TTL_MS) return true;
  seenRequests.set(id, now);
  return false;
}

// --- Global mode flag: swap between Metorial (tools) and OpenAI-only ---
const USE_METORIAL = String(process.env.USE_METORIAL || "").toLowerCase() === "true";

// --- Metorial + LLM setup ---
const METORIAL_API_KEY = process.env.METORIAL_API_KEY;
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
const OPENAI_MODEL = process.env.OPENAI_MODEL || "gpt-4o";
const METORIAL_MAX_STEPS = Number(process.env.METORIAL_MAX_STEPS || 12);

// Allow a comma-separated list of server deployments (by ID or name)
const SERVER_DEPLOYMENTS = (process.env.METORIAL_SERVER_DEPLOYMENTS || "")
  .split(",")
  .map(s => s.trim())
  .filter(Boolean);

const metorial = new Metorial({ apiKey: METORIAL_API_KEY });
const openai = new OpenAI({ apiKey: OPENAI_API_KEY });

app.get("/healthz", (_req, res) => res.status(200).send("ok"));

// Utility: safe filenames
function safe(s) {
  return String(s || "")
    .replaceAll(/[^\w.\-]+/g, "_")
    .slice(0, 64);
}

// ---------- Unified output schemas ----------
// Full (for tools route)
const EvidenceSchema = z.object({
  claim: z.string().optional().describe("Text of the claim being discussed."),
  explanation: z.string().optional().describe("Reasoned explanation in concise prose."),
  status: z.enum(["FACTUALLY_INCORRECT","POSSIBLY_INCORRECT","NEEDS_REVIEW","SUPPORTED"]).optional()
    .describe("Classifier for the claim."),
  citations: z.array(z.string().url()).optional().describe("URLs that support the judgment.")
});
const AnalysisSchemaFull = z.object({
  replacementChunk: z.union([z.string(), z.null()]).nullable().optional()
    .describe("If corrections are needed, provide a corrected version; otherwise null."),
  evidence: z.array(EvidenceSchema).optional()
    .describe("Optional evidence list. Omit when using the OpenAI-only path.")
}).describe("Unified analysis result.");

// Replacement-only (for OpenAI-only path, no evidence)
const AnalysisSchemaReplacementOnly = z.object({
  replacementChunk: z.union([z.string(), z.null()])
    .describe("If corrections are needed, provide a corrected version; otherwise null.")
});


// Build the model message for metorial.run()
function buildPromptMetorial(payload) {
  const userText = payload?.typedTextChunk || "";
  const windowTitle = payload?.window?.title || "";
  return `
You are a precise, tool-using fact checker. You will receive some text that a user recently typed, along with the application window title that the user was in when they typed this text.
Your goal is to determine the most relevant sources of data for you to retrieve in order to better establish the veracity of what the user typed.

CONTEXT:
- Window title: "${windowTitle}"
- User text (verbatim):
"""${userText}"""

TASK:
1) Determine the most relevant sources of data for the user text and the context of the window title.
2) Using the available MCP servers (provided to you), iteratively gather supporting/contradictory context.
3) If the available data implies an error in the text, you must output a corrected version of the text.
4) If the available data implies there is no error in the text, you must output null or the empty string. 

Never ask for confirmation.

YOUR FINAL OUTPUT MUST EITHER BE NULL/'' OR THE CORRECTED USER TEXT:`
}

function buildPromptOpenAI(payload) {
  const userText = payload?.typedTextChunk || "";
  const windowTitle = payload?.window?.title || "";
  return `
You are a precise, tool-using fact checker. You will receive some text that a user recently typed, along with the application window title that the user was in when they typed this text.
Your goal is to establish the veracity of what the user typed, inferring from text and window title when they have made a false claim.


CONTEXT:
- Window title: "${windowTitle}"
- User text (verbatim):
"""${userText}"""

OUTPUT (STRICT JSON):
{
  "replacementChunk": "string | null"
}
RULES:
- If the text appears correct, return {"replacementChunk": null}.
- Do NOT include an "evidence" field in the output.
No prose; JSON only.`
}

async function openaiReplacementOnly(payload) {
  const completion = await openai.chat.completions.parse({
    model: OPENAI_MODEL,
    messages: [{ role: "system", content: buildPromptOpenAI(payload) }],
    verbosity: "low",
    reasoning_effort: "minimal",
    response_format: zodResponseFormat(AnalysisSchemaReplacementOnly, "ChunkCorrection")
  });
  // `.parsed` is validated by zodResponseFormat
  console.log(JSON.stringify(completion))
  const parsed = completion.choices[0].message.parsed;
  console.log(parsed)
  // Ensure final object shape
  console.log("final response " + parsed?.replacementChunk)
  return { replacementChunk: parsed?.replacementChunk ?? null };
}



app.post("/analyze", async (req, res) => {
  const reqId = req.get("X-Request-Id") || null;
  if (isDuplicate(reqId)) {
    console.log(`(duplicate) X-Request-Id=${reqId} — ignored`);
    return res.status(200).json({ ok: true, duplicate: true });
  }
  const p = req.body; // AnalysisPayload
  const t0 = performance.now();
  // Always print summary + save screenshot (carryover from Phase 4.5)
  try {
    const ts = p.timestamp || new Date().toISOString();
    const appName = p.app?.name || "App";
    const bundleId = p.app?.bundleId || "";
    const winTitle = p.window?.title || "";
    const text = p.typedTextChunk || "";

    console.log("-".repeat(60));
    console.log(`[${ts}] ${appName}${bundleId ? " (" + bundleId + ")" : ""}`);
    if (winTitle) console.log(`Window: ${winTitle}`);
    console.log(`Text (${text.length} chars):`);
    console.log(text.length > 240 ? text.slice(0, 240) + " …" : text);

    if (p.screenshot?.dataBase64 && p.screenshot?.mime) {
      const buf = Buffer.from(p.screenshot.dataBase64, "base64");
      const ext = p.screenshot.mime === "image/png" ? ".png" : ".jpg";
      const stamp = ts.replaceAll(/[:.]/g, "-");
      const file = `${stamp}_${safe(appName)}_${safe(p.window?.id)}${ext}`;
      const outPath = path.join(shotsDir, file);
      fs.writeFileSync(outPath, buf);
      console.log(`Saved screenshot - ${outPath} (${buf.length} bytes)`);
    } else {
      console.log("No screenshot in payload.");
    }
  } catch (err) {
    console.error("Preprocessing error:", err);
    // We keep going; metorial call can still run without screenshot
  }

  // Short-circuit if keys are missing: return stubbed result
  if (!OPENAI_API_KEY || (USE_METORIAL && !METORIAL_API_KEY)) {
    console.warn(`Missing required API key(s) for mode=${USE_METORIAL ? "metorial" : "openai"}. Returning stubbed result.`);
    return res.status(200).json({ replacementChunk: null });

  }

  // Compose prompt and call the selected backend
  try {
    if (!USE_METORIAL) {
      // OpenAI-only path
      const tLLM0 = performance.now();
      const result = await openaiReplacementOnly(p);
      const tLLM1 = performance.now();
      console.log(`Timing(openai): LLM ${(tLLM1 - tLLM0).toFixed(0)} ms`);
      return res.status(200).json(result);

    } else {
      // Metorial (tools) path
      const message = buildPromptMetorial(p);
      const serverDeployments = SERVER_DEPLOYMENTS.length ? SERVER_DEPLOYMENTS : [];
      const tLLMTools0 = performance.now();
      const resultTools = await metorial.run({
        message,
        serverDeployments,
        model: OPENAI_MODEL,
        client: openai,
        maxSteps: METORIAL_MAX_STEPS
      });
      const tLLMTools1 = performance.now();
      const t1 = performance.now();
      const toolOut = (!resultTools.text || resultTools.text==="" || resultTools.text==="null") ? null :resultTools.text;
      console.log("toolResp:", toolOut);
      console.log(`Timing(metorial): LLM ${(tLLMTools1 - tLLMTools0).toFixed(0)} ms | total ${(t1 - t0).toFixed(0)} ms`);
      const response = { replacementChunk: toolOut ?? null };
      return res.status(200).json(response);
    }
  } catch (err) {
    console.error("Analyze error:", err);
    return res.status(500).json({ ok: false, error: String(err) });
  }
});

app.listen(PORT, () => {
  console.log(`Analyzer server listening on http://127.0.0.1:${PORT}`);
  console.log(`Screenshots saved under: ${shotsDir}`);
});
