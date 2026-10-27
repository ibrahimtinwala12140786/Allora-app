// Allora AI — Enterprise Multi-Engine AI Orchestrator
//
// Powered by:
// 1. Groq Ultra-Fast LPU Engine (sub-second response times)
// 2. Google Gemini Direct Engine (deep reasoning & precision)
// 3. OpenRouter Universal Failover (global model redundancy)
//
// Automatically fails over across providers with zero downtime.

const GROQ_MODELS = [
  "openai/gpt-oss-120b",
  "openai/gpt-oss-20b",
  "qwen/qwen3.8-27b",
  "groq/compound",
];

const GEMINI_MODELS = [
  "gemini-3.5-flash-lite", // 500 RPD, 15 RPM (High Quota)
  "gemini-3.1-flash-lite", // 500 RPD, 15 RPM (High Quota)
  "gemini-3.6-flash",      // High Quality Flash
  "gemini-3.5-flash",      // High Quality Flash
  "gemini-3.7-flash",      // Latest Preview
];

const OPENROUTER_MODELS = [
  "google/gemini-3.6-flash",
  "google/gemini-3.7-flash",
  "deepseek/deepseek-v4-flash-0731",
  "meta-llama/llama-3.3-70b-instruct",
];

const MAX_TOKENS = 1000;

type Msg = { sender?: string; text?: string; role?: string };

interface AiRequest {
  task: string;
  text?: string;
  tone?: string;
  language?: string;
  prompt?: string;
  context?: Msg[];
  history?: Msg[];
}

const TONES: Record<string, string> = {
  professional: "a polished, professional tone",
  friendly: "a warm, friendly tone",
  romantic: "a sweet, romantic tone",
  formal: "a formal, respectful tone",
  funny: "a light, funny tone",
  shorter: "the same tone but noticeably shorter",
  longer: "the same tone but more detailed",
};

function contextBlock(context: Msg[] | undefined): string {
  if (!context?.length) return "";
  const lines = context
    .slice(-20)
    .map((m) => `${(m.sender ?? "?").slice(0, 40)}: ${(m.text ?? "").slice(0, 800)}`)
    .join("\n");
  return `\n\nConversation (oldest first):\n${lines}`;
}

function buildPrompt(req: AiRequest): { system: string; user: string } {
  const base =
    "You are Allora AI, the writing assistant inside the Allora messenger. " +
    "Reply with ONLY the requested text — no preamble, no quotes, no markdown fences.";
  const t = (req.text ?? "").slice(0, 4000);

  switch (req.task) {
    case "rewrite":
      return {
        system: base,
        user: `Rewrite this message in ${TONES[req.tone ?? ""] ?? "a clearer way"}. Keep the meaning and the language of the original.\n\n${t}`,
      };
    case "grammar":
      return {
        system: base,
        user: `Fix spelling and grammar. Change nothing else. Keep the original language.\n\n${t}`,
      };
    case "translate":
      return {
        system: base,
        user: `Translate to ${req.language ?? "English"}. Natural, conversational register.\n\n${t}`,
      };
    case "explain":
      return {
        system: base.replace("ONLY the requested text", "a short, clear explanation"),
        user: `Explain what this message means (intent, idioms, tone). 2-4 sentences.\n\n${t}`,
      };
    case "detect_tone":
      return {
        system: base,
        user: `In one short sentence, describe the tone of this message:\n\n${t}`,
      };
    case "compose":
      return {
        system: base,
        user: `Write a message for me. ${req.tone ? `Use ${TONES[req.tone] ?? req.tone}. ` : ""}Task: ${(req.prompt ?? "").slice(0, 1000)}`,
      };
    case "summarize":
      return {
        system: base.replace("ONLY the requested text", "a compact summary"),
        user: `Summarize this conversation in 3-6 bullet points (use • ). Include decisions and open questions.${contextBlock(req.context)}`,
      };
    case "extract":
      return {
        system: base.replace("ONLY the requested text", "a compact list"),
        user: `From this conversation, extract action items, dates/times, and places as short bullet points grouped under "Tasks", "Dates", "Places". Write "None found" for empty groups.${contextBlock(req.context)}`,
      };
    case "reply":
      return {
        system: base,
        user: `${(req.prompt ?? "Suggest the best reply").slice(0, 500)}. Write it as me ("Me" in the transcript), matching the conversation's language and tone.${contextBlock(req.context)}`,
      };
    case "smart_replies":
      return {
        system:
          "You suggest quick replies inside a messenger. Output EXACTLY three replies separated by newlines. Each under 8 words, in the conversation's language, no numbering, no quotes.",
        user: `Suggest three quick replies I could send next.${contextBlock(req.context)}`,
      };
    case "chat":
      return { system: "", user: "" };
    default:
      return { system: base, user: t || (req.prompt ?? "") };
  }
}

// ── 1. Groq Engine ─────────────────────────────────────────────────────────

async function callGroq(
  apiKey: string,
  system: string,
  messages: { role: string; content: string }[],
  modelIndex: number = 0
): Promise<string> {
  const model = GROQ_MODELS[modelIndex];
  if (!model) {
    throw new Error("All Groq models exhausted");
  }

  const chatMessages = [
    ...(system ? [{ role: "system", content: system }] : []),
    ...messages.map((m) => ({
      role: m.role === "assistant" ? "assistant" : "user",
      content: m.content,
    })),
  ];

  const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      max_tokens: MAX_TOKENS,
      messages: chatMessages,
    }),
  });

  if (!res.ok) {
    if (modelIndex < GROQ_MODELS.length - 1) {
      console.log(`Groq ${model} returned ${res.status}, trying fallback ${GROQ_MODELS[modelIndex + 1]}`);
      return callGroq(apiKey, system, messages, modelIndex + 1);
    }
    const errText = await res.text();
    throw new Error(`Groq Error ${res.status}: ${errText.slice(0, 200)}`);
  }

  const data = await res.json();
  const text = data.choices?.[0]?.message?.content;
  if (!text) {
    throw new Error("Empty response from Groq");
  }
  return text.trim();
}

// ── 2. Google Gemini Direct Engine ─────────────────────────────────────────

async function callGoogleGemini(
  apiKey: string,
  system: string,
  messages: { role: string; content: string }[],
  modelIndex: number = 0
): Promise<string> {
  const model = GEMINI_MODELS[modelIndex];
  if (!model) {
    throw new Error("All Google Gemini models exhausted");
  }

  const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;
  const contents = messages.map((m) => ({
    role: m.role === "assistant" ? "model" : "user",
    parts: [{ text: m.content }],
  }));

  const body: any = {
    contents,
    generationConfig: {
      maxOutputTokens: MAX_TOKENS,
    },
  };

  if (system) {
    body.systemInstruction = {
      parts: [{ text: system }],
    };
  }

  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    if (modelIndex < GEMINI_MODELS.length - 1) {
      console.log(`Gemini ${model} returned ${res.status}, trying fallback ${GEMINI_MODELS[modelIndex + 1]}`);
      return callGoogleGemini(apiKey, system, messages, modelIndex + 1);
    }
    const errText = await res.text();
    throw new Error(`Google Gemini Error ${res.status}: ${errText.slice(0, 200)}`);
  }

  const data = await res.json();
  const text = data.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) {
    throw new Error("Empty candidate in Google Gemini response");
  }
  return text.trim();
}

// ── 3. OpenRouter Universal Failover Engine ────────────────────────────────

async function callOpenRouter(
  apiKey: string,
  system: string,
  messages: { role: string; content: string }[],
  modelIndex: number = 0
): Promise<string> {
  const model = OPENROUTER_MODELS[modelIndex];
  if (!model) {
    throw new Error("All OpenRouter models exhausted");
  }

  const chatMessages = [
    ...(system ? [{ role: "system", content: system }] : []),
    ...messages.map((m) => ({
      role: m.role === "assistant" ? "assistant" : "user",
      content: m.content,
    })),
  ];

  const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
      "HTTP-Referer": "https://allorachat.app",
      "X-Title": "Allora",
    },
    body: JSON.stringify({
      model,
      max_tokens: MAX_TOKENS,
      messages: chatMessages,
    }),
  });

  if (!res.ok) {
    if (modelIndex < OPENROUTER_MODELS.length - 1) {
      console.log(`OpenRouter ${model} returned ${res.status}, trying fallback ${OPENROUTER_MODELS[modelIndex + 1]}`);
      return callOpenRouter(apiKey, system, messages, modelIndex + 1);
    }
    const errText = await res.text();
    throw new Error(`OpenRouter Error ${res.status}: ${errText.slice(0, 200)}`);
  }

  const data = await res.json();
  const text = data.choices?.[0]?.message?.content;
  if (!text) {
    throw new Error("Empty response from OpenRouter");
  }
  return text.trim();
}

// ── Multi-Engine Orchestrator (Failover Pipeline) ──────────────────────────

async function callAiPipeline(
  groqKey: string | undefined,
  geminiKey: string | undefined,
  openRouterKey: string | undefined,
  system: string,
  messages: { role: string; content: string }[]
): Promise<string> {
  let lastError: any = null;

  // 1. Try Groq first for blazing sub-second inference
  if (groqKey) {
    try {
      return await callGroq(groqKey, system, messages);
    } catch (e: any) {
      console.warn("Groq provider failed, falling back to Google Gemini:", e.message);
      lastError = e;
    }
  }

  // 2. Try Google Gemini Direct next
  if (geminiKey) {
    try {
      return await callGoogleGemini(geminiKey, system, messages);
    } catch (e: any) {
      console.warn("Google Gemini provider failed, falling back to OpenRouter:", e.message);
      lastError = e;
    }
  }

  // 3. Fallback to OpenRouter
  if (openRouterKey) {
    try {
      return await callOpenRouter(openRouterKey, system, messages);
    } catch (e: any) {
      console.warn("OpenRouter provider failed:", e.message);
      lastError = e;
    }
  }

  if (lastError) {
    throw lastError;
  }

  throw new Error("AI backend not configured (missing GROQ_API_KEY, GEMINI_API_KEY, and OPENROUTER_API_KEY).");
}

// ── Server Handler ─────────────────────────────────────────────────────────

(globalThis as any).Deno.serve(async (request: Request) => {
  const headers = { "content-type": "application/json" };
  try {
    const groqKey = (globalThis as any).Deno.env.get("GROQ_API_KEY");
    const geminiKey = (globalThis as any).Deno.env.get("GEMINI_API_KEY");
    const openRouterKey = (globalThis as any).Deno.env.get("OPENROUTER_API_KEY");

    if (!groqKey && !geminiKey && !openRouterKey) {
      return new Response(
        JSON.stringify({ ok: false, error: "AI backend not configured (missing API keys)." }),
        { status: 500, headers }
      );
    }

    const req = (await request.json()) as AiRequest;

    if (req.task === "chat") {
      const history = (req.history ?? []).slice(-24);
      const messages = history
        .filter((m) => (m.text ?? "").trim().length > 0)
        .map((m) => ({
          role: m.role === "assistant" ? "assistant" : "user",
          content: (m.text ?? "").slice(0, 4000),
        }));
      if (messages.length === 0 || messages[messages.length - 1].role !== "user") {
        return new Response(
          JSON.stringify({ ok: false, error: "Nothing to respond to." }),
          { status: 400, headers }
        );
      }
      const text = await callAiPipeline(
        groqKey,
        geminiKey,
        openRouterKey,
        "You are Allora AI, a concise, helpful assistant inside the Allora messenger. " +
          "You help with writing, translating, summarizing and everyday questions. Keep answers tight.",
        messages
      );
      return new Response(JSON.stringify({ ok: true, text }), { headers });
    }

    const { system, user } = buildPrompt(req);
    if (!user.trim()) {
      return new Response(
        JSON.stringify({ ok: false, error: "Empty request." }),
        { status: 400, headers }
      );
    }
    const text = await callAiPipeline(groqKey, geminiKey, openRouterKey, system, [{ role: "user", content: user }]);

    if (req.task === "smart_replies") {
      const suggestions = text
        .split("\n")
        .map((s) => s.replace(/^[-•*\d.\s"]+|["\s]+$/g, "").trim())
        .filter((s) => s.length > 0 && s.length <= 60)
        .slice(0, 3);
      return new Response(JSON.stringify({ ok: true, suggestions }), { headers });
    }

    return new Response(JSON.stringify({ ok: true, text }), { headers });
  } catch (e: any) {
    console.error("allora-ai:", e);
    const errorMessage = e.message || "The AI service hit an error. Try again.";
    return new Response(
      JSON.stringify({ ok: false, error: errorMessage }),
      { status: 500, headers }
    );
  }
});
