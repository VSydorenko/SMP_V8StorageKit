<!-- Ported from agent-kit 0.9.1 skills/retro/references/evidence.md, modified. -->
# Докази з минулої сесії

**Завантаж, коли** власник називає сесію, що не є поточною.

Транскрипти: `~/.claude/projects/<slug>/<session-id>.jsonl`, де `<slug>` — шлях проєкту, де кожен символ, що не є літерою чи цифрою, замінено на `-` (`R:\github\SMP_V8StorageKit` → `R--github-SMP-V8StorageKit`). Субагенти: `<session-id>/subagents/*.jsonl`. Знайди сесію за фразою, яку пам'ятає власник:

```bash
grep -l "<фраза>" ~/.claude/projects/<slug>/*.jsonl
```

Не читай транскрипт цілим — це мегабайти. Витягай:

```bash
T=~/.claude/projects/<slug>/<session-id>.jsonl
# Повідомлення власника й сесій-колег (результати інструментів і вставлені нагадування пропущено)
node -e 'for (const l of require("fs").readFileSync(process.argv[1],"utf8").split("\n")) { let o; try { o = JSON.parse(l) } catch { continue }
  if (o.type !== "user") continue; const c = o.message?.content;
  let t = typeof c === "string" ? c : Array.isArray(c) ? c.filter((x) => x.type === "text").map((x) => x.text).join(" ") : "";
  // Сесії-колеги приходять як мета-записи; повернення субагентів (<agent-message>) не є поправками.
  const peer = t.match(/<cross-session-message[^>]*from-name="([^"]*)"[^>]*>([\s\S]*?)<\/cross-session-message>/);
  if (peer) t = `[${peer[1]}] ${peer[2]}`; else if (o.isMeta || !t || t.startsWith("<")) continue;
  console.log(o.timestamp?.slice(0,16), t.replace(/\s+/g," ").slice(0,300)) }' "$T"
# Команди Bash за першими двома словами справжньої команди (`cd … &&` і VAR=… пропущено)
node -e 'const n = {}; for (const l of require("fs").readFileSync(process.argv[1],"utf8").split("\n")) { let o; try { o = JSON.parse(l) } catch { continue }
  for (const x of (o.type === "assistant" ? o.message.content : [])) if (x.name === "Bash") {
    const cmd = x.input.command.trim().replace(/^(cd \S+\s*(&&|;)\s*|[A-Z_]+=\S*\s+)+/, "");
    const k = cmd.split(/\s+/).slice(0,2).join(" "); n[k] = (n[k] ?? 0) + 1 } }
  for (const [k,v] of Object.entries(n).sort((a,b) => b[1]-a[1]).slice(0,25)) console.log(String(v).padStart(4), k)' "$T"
```

Вартість і контекст: `session-cost -Project <репо> -Session <session-id> -By agent`.
