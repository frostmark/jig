let result = null;
let init = null;
for (const line of require("fs").readFileSync(0, "utf8").split("\n")) {
  if (!line.startsWith("{")) continue;
  let m;
  try { m = JSON.parse(line); } catch (e) { continue; }
  if (!m || typeof m !== "object") continue;
  if (m.type === "result") result = m;
  else if (m.type === "system" && m.subtype === "init" && !init) init = m;
}
if (process.argv[1] === "meta") {
  let meta = "";
  if (result) {
    const cost = typeof result.total_cost_usd === "number" ? `, estimated cost $${result.total_cost_usd.toFixed(2)}` : "";
    const outcome = result.is_error ? `error (${result.subtype})` : result.subtype;
    meta = `${outcome}, turns: ${result.num_turns}${cost}`;
  }
  const usage = result && result.modelUsage && typeof result.modelUsage === "object" ? Object.keys(result.modelUsage) : [];
  const models = [];
  for (const name of [init && init.model, ...usage]) {
    if (typeof name === "string" && /^[A-Za-z0-9][A-Za-z0-9._:@\/\[\]-]{0,99}$/.test(name) && !models.includes(name)) models.push(name);
  }
  process.stdout.write(`${meta}\n${models.join(" ")}\n`);
} else {
  if (!result) process.exit(1);
  process.stdout.write(typeof result.result === "string" ? result.result : "");
}
