# Demo recordings

Terminal captures of the demo beats. `.cast` files replay with `asciinema play`;
the `.gif` versions drop straight into a slide. The live-AWS beat was recorded
against real infrastructure in eu-west-1 and torn down afterwards.

| Beat | Length | What it shows |
|---|---|---|
| `beat1-contrast` | 42s | The same request without the platform (389 lines) and with it (12) |
| `beat3-kiro` | 109s | Kiro CLI: one sentence becomes a validated manifest, tool calls visible |
| `beat3-claude` | 87s | Claude Code doing the same through the same `SKILL.md` |
| `beat4-blocked` | **127s** | **An agent asks for `xlarge` in dev, is refused, and fixes itself** |
| `beat4-attacks` | 52s | All four attack fixtures refused, each by a different ring |
| `beat5-live` | 35s | 40 real resources, HTTP 200, the unasked-for dashboard and SLO, ring 5 |

## Which one to show

`beat4-blocked` is the climax. The agent asks for an `xlarge` database in dev,
hits the policy, reads the denial, and settles on `medium` with no human
involved. It also repeats the reason back: sixteen times the cost, and the last
three times the real problem was a missing index. That line comes from
`.kiro/steering/cost.md`, which is the proof that the steering file is doing
work rather than decorating the repo.

The recording shows the rule first, then the reason, then the request, then the
verbatim denial, then the diff, then every ring passing. Slow on purpose: the
denial's wording is the argument, so the audience needs time to read it.

## antidemo/

The Terraform a current model wrote for "I need a postgres database for a new
reporting service on AWS" with no steering files, no skill and no schema.

Keep it. It is the evidence behind the numbers on the Act 1 slide. Note what it
got *right* unprompted: `storage_encrypted`, `publicly_accessible = false` and
`manage_master_user_password`. The argument is not that the model writes
insecure code. It is 389 lines across five files, nineteen free variables with
no policy behind any of them, and the VPC handed back to the person least able
to answer it.

## Re-recording

```bash
asciinema rec recording/<beat>.cast --window-size 150x46 \
  --command ./recording/<beat>.sh --overwrite
agg --font-size 18 --theme asciinema recording/<beat>.cast recording/<beat>.gif
```

150 columns is the floor. The policy denials wrap below about 140, and a
wrapped denial is unreadable from the back of a room.

`streamfmt.py` turns Claude Code's `--output-format stream-json` into readable
`[skill]`, `[read]`, `[run]` lines. Without it the stream is raw JSON, which
shows the same information and communicates none of it.

The agent beats are live, so the wording varies between takes. Everything that
matters is deterministic: it will hit the same denial and settle on the same
size, because that part is policy rather than prose.

## Kiro

```bash
kiro-cli user login --license free
./recording/beat3-kiro.sh
```

`kiro-cli` is symlinked into `/opt/homebrew/bin`; the cask installs it inside
`/Applications/Kiro CLI.app/` and does not put it on `PATH`.
