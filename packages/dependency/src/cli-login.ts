import { login } from "./auth.js";

login()
  .then((auth) => {
    console.log(`Signed in. account_id=${auth.account_id}`);
  })
  .catch((err) => {
    console.error("Login failed:", err.message ?? err);
    process.exit(1);
  });
