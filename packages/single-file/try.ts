import { chat } from "./chatgpt-codex-auth.js";

const prompt = process.argv.slice(2).join(" ") || "Say hello in one short sentence.";

await chat([{ role: "user", content: prompt }], {
  onDelta: (text) => process.stdout.write(text),
});
process.stdout.write("\n");
