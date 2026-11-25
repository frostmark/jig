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
  const parts = [];
  if (result) {
    const subtype = typeof result.subtype === "string" && /^[a-z_]{1,40}$/.test(result.subtype) ? result.subtype : "";
    if (result.is_error) parts.push(subtype ? `error (${subtype})` : "error");
    else if (subtype) parts.push(subtype);
    const turns = result.num_turns;
    if (Number.isInteger(turns) && turns >= 0 && turns <= 999999) parts.push(`turns: ${turns}`);
    const cost = typeof result.total_cost_usd === "number" ? result.total_cost_usd.toFixed(2) : "";
    if (/^[0-9]{1,6}\.[0-9]{2}$/.test(cost)) parts.push(`estimated cost $${cost}`);
  }
  const valid = (name) => typeof name === "string" && /^[A-Za-z0-9][A-Za-z0-9._:@\/\[\]-]{0,99}$/.test(name);
  const main = init && valid(init.model) ? init.model : "";
  const usage = result && result.modelUsage && typeof result.modelUsage === "object" ? Object.keys(result.modelUsage) : [];
  const others = usage.filter((name) => name !== main && valid(name));
  process.stdout.write(`${parts.join(", ")}\n${main}\n${[others.length, ...others.slice(0, 5)].join(" ")}\n`);
} else {
  if (!result) process.exit(1);
  process.stdout.write(typeof result.result === "string" ? result.result : "");
}
