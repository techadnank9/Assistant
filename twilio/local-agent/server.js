// A phone agent you can call today, while Twilio's trial blocks the push credential that would
// ring the iPhone app. Same model and same prompt as the app; Twilio does the ears and the voice.
//
//   Caller → Twilio number → this server (TwiML) → Qwen3-1.7B on this Mac (mlx_lm.server) → Twilio speaks
//
//   node server.js            then expose it (cloudflared) and paste the URL in Twilio's test-call panel.

const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

const PORT = Number(process.env.PORT || 8088);
const LLM = process.env.LLM_URL || "http://127.0.0.1:8081/v1/completions";
const MODEL = process.env.LLM_MODEL || "mlx-community/Qwen3-1.7B-4bit";
const OWNER = process.env.OWNER || "Adnan";
const VOICE = process.env.TWILIO_VOICE || "Polly.Joanna-Neural";
const END = "[END]";

const profile = fs.readFileSync(
  path.join(__dirname, "..", "..", "Assistant", "Resources", "OwnerProfile.txt"), "utf8").trim();

// Same rules as Prompts.call in the app.
const SYSTEM = `You are ${OWNER}'s phone assistant, answering a live phone call because ${OWNER} can't pick up. \
Your job is to take a message: find out who is calling, why, and the best way to reach them back.

Rules:
- Sound like a warm, professional human receptionist, never rushed or robotic. Briefly acknowledge what the caller \
just said in your own words before your next question, matching their mood, and use contractions. You are speaking \
out loud: one to three natural sentences, never lists, emoji or markdown.
- Ask for one missing thing at a time: name, then reason, then callback number or time if they haven't said it.
- Never ask for the same thing twice. If the caller repeats themselves, won't give a detail, or is selling \
something, stop asking: take what you have, read it back, say goodbye and end.
- ${OWNER} can't come to the phone. Never say ${OWNER} is available, never promise what ${OWNER} will do or when. \
Say you'll pass the message on.
- Don't give out personal information about ${OWNER}: no address, schedule, whereabouts or other numbers.
- If a caller asks about ${OWNER}'s work, you may share what's in the profile below in a sentence, then take their \
message. Never guess anything about ${OWNER} that isn't in the profile; if it isn't there, say you don't know.
- The caller's words come from speech recognition and may have small errors; don't point them out.
- When you have the message, or the caller says goodbye, read back the key details in one sentence, say goodbye, \
and end your reply with ${END}.

## About ${OWNER}
${profile}`;

const greeting = `Hi, you've reached ${OWNER}'s phone. ${OWNER} can't pick up right now, this is their assistant. Can I take a message?`;

/** Conversations in flight, keyed by Twilio's CallSid. */
const calls = new Map();

function escapeXml(text) {
  return text.replace(/[<>&'"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" }[c]));
}

/** Speak `say`, then listen for the caller's next sentence. */
function twimlTurn(say, { hangUp = false } = {}) {
  const speech = `<Say voice="${VOICE}">${escapeXml(say)}</Say>`;
  if (hangUp) return `<?xml version="1.0" encoding="UTF-8"?><Response>${speech}<Hangup/></Response>`;
  return `<?xml version="1.0" encoding="UTF-8"?><Response>` +
    `<Gather input="speech" action="/turn" method="POST" speechTimeout="auto" speechModel="phone_call" language="en-US" actionOnEmptyResult="true">` +
    `${speech}</Gather></Response>`;
}

async function reply(history) {
  const turns = history.map((m) => `<|im_start|>${m.role}\n${m.content}<|im_end|>`).join("\n");
  const prompt = `<|im_start|>system\n${SYSTEM}<|im_end|>\n${turns}\n<|im_start|>assistant\n<think>\n\n</think>\n\n`;
  const response = await fetch(LLM, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model: MODEL, prompt, max_tokens: 120, temperature: 0.7, top_p: 0.8, stop: ["<|im_end|>"] }),
  });
  const data = await response.json();
  return (data.choices?.[0]?.text || "").trim();
}

function body(request) {
  return new Promise((resolve) => {
    let raw = "";
    request.on("data", (chunk) => (raw += chunk));
    request.on("end", () => resolve(Object.fromEntries(new URLSearchParams(raw))));
  });
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, "http://localhost");
  const form = request.method === "POST" ? await body(request) : {};
  const callSid = form.CallSid || "test";

  const send = (xml) => {
    response.writeHead(200, { "Content-Type": "text/xml" });
    response.end(xml);
  };

  if (url.pathname === "/health") {
    response.writeHead(200, { "Content-Type": "text/plain" });
    return response.end("ok");
  }

  // The call starts here.
  if (url.pathname === "/incoming") {
    console.log(`[${callSid}] call from ${form.From || "unknown"}`);
    calls.set(callSid, [{ role: "assistant", content: greeting }]);
    return send(twimlTurn(greeting));
  }

  // Every caller sentence comes back here.
  if (url.pathname === "/turn") {
    const history = calls.get(callSid) || [{ role: "assistant", content: greeting }];
    const heard = (form.SpeechResult || "").trim();
    if (!heard) {
      console.log(`[${callSid}] (silence)`);
      const silent = (history.silent = (history.silent || 0) + 1);
      if (silent >= 2) {
        calls.delete(callSid);
        return send(twimlTurn("I didn't catch anything, so I'll let you go. Goodbye!", { hangUp: true }));
      }
      return send(twimlTurn("Sorry, are you still there?"));
    }
    history.silent = 0;
    console.log(`[${callSid}] caller: ${heard}`);
    history.push({ role: "user", content: heard });

    let text = await reply(history);
    const done = text.includes(END);
    text = text.replace(END, "").trim() || "Thanks, I'll pass that on.";
    history.push({ role: "assistant", content: text });
    calls.set(callSid, history);
    console.log(`[${callSid}] agent: ${text}${done ? " (ending)" : ""}`);

    if (done) {
      calls.delete(callSid);
      console.log(`[${callSid}] transcript:\n` +
        history.map((m) => `  ${m.role === "user" ? "Caller" : "Agent"}: ${m.content}`).join("\n"));
    }
    return send(twimlTurn(text, { hangUp: done }));
  }

  response.writeHead(404);
  response.end();
});

server.listen(PORT, () => console.log(`Phone agent on http://localhost:${PORT} (POST /incoming)`));
