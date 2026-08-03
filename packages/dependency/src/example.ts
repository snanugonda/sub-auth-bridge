import { chat } from "./client.js";

const prompt = process.argv.slice(2).join(" ") || "Say hello in one sentence.";

await chat([{ role: "user", content: prompt }], {
  model: process.env.CODEX_MODEL,
  onDelta: (text) => process.stdout.write(text),
});
process.stdout.write("\n");
