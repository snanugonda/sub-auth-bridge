import { chat, imageFromFile } from "./chatgpt-codex-auth.js";

const imagePath = process.argv[2];
if (!imagePath) throw new Error("Usage: tsx try-image.ts <path-to-image>");

const out = await chat([
  {
    role: "user",
    content: [
      { type: "text", text: "What text is in this image? Reply with just the text." },
      imageFromFile(imagePath),
    ],
  },
]);
console.log(out);
