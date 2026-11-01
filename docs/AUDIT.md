# Audit: the NovaWorldBuffs listener (untrusted guild addon messages)

Issue #1, branch `audit/nwb`; row #5 of the owner's audit list, shared with GlassPanel's `Share.lua`
(GlassPanel #131, its own `docs/AUDIT.md`). The question audited, as one property: **any
`CHAT_MSG_ADDON` on the `NWB` prefix either sets one sender's layer to an integer 1..50 (0 clears it)
or is ignored; never a throw; bytes retained per sender and CPU per message bounded before anything is
decoded.** The plan was reviewed with Codex gpt-6-astra (medium) in three rounds to consensus
(2026-10-30/31).

Context: NovaWorldBuffs has no Forever port, so on Forever the only input is a guild member deliberately
sending on the prefix; the TOC also lists the Classic clients where NWB is live. A guild addon message
is echoed to its sender (the porting guide), so the own-message skip matters.

## 1. Trace

GUILD only, own messages skipped → `HandleAceCommFraming` (a per-sender spool: `\001` first, `\002`
middle, `\003` last, `\004` escape) → `DecodeNWBMessage`: `DecodeForWoWAddonChannel` →
`DecompressDeflate` (LibDeflate 1.0.1: **no output cap**; raw deflate, so **no checksum**) →
`LibSerialize`, else `AceSerializer` (both fail safely on garbage) → `ProcessNWBMessage`: `Explode`,
`strsplit("-", args[3], 2)`, `tonumber`, range, store in `nwbGuildLayers`, `RebuildNWBLayerCounts`
(`nwbLayerCounts[layer]`), the tooltip's `for i = 1, nwbMaxLayer`. `tests/port.lua` never loaded the
libraries or touched this path.

## 2. Findings and fixes

Read first, confirmed by a test that fails with the fix reverted ("witness"). Lines as before the fix.

| # | Finding | Fix | Witness (reverted → red) |
|---|---|---|---|
| T1 | `layerNum < 0 or layerNum > 50` let a NaN through (`tonumber("nan")` on a C99 runtime; the client's is unmeasured). It was stored, then `nwbLayerCounts[NaN]` threw "table index is NaN" (line 345) on that message and on every later one from anyone. A fraction was accepted too ("X/2.5" on the bar, a count the tooltip never showed) | an integer 0..50, checked before the store: `% 1 ~= 0` rejects NaN, inf and fractions | `tests/nwb.lua` "a fractional layer is refused", "a NaN layer doesn't throw" (the test plays the C99 runtime), "the next report doesn't throw either", "and it counts" (4) |
| T2+T3 | the spool appended middle parts without limit, and nothing bounded what reached `DecompressDeflate`: a guild member could make the client retain and inflate as much as they sent (measured offline: 400 parts retained 121 KB) | `NWB_MAX_BYTES`, 4096 encoded bytes per message, enforced on single, escaped, first, middle and last frames **before decoding**; over it the key is dropped. NWB's large data broadcasts on the same prefix fall to this, which costs nothing TitanLayer reads. A deflate bomb is bounded, not detected: about 1 MB inflated at most (4 KB at deflate's ~1032:1) | "a report of 4097 encoded bytes is refused as multipart", "a single frame over the budget is refused", "an escaped frame over the budget is refused", "an unfinished sender retains at most the budget" (121 KB → 0), "its last part assembles nothing" (5); the boundary "a report of 4096 encoded bytes is accepted" and "400 KB of zeros encode under the budget … decodes without a throw" hold on both sides |
| T2b | a partial message stayed in the spool for the session | `NWB_SPOOL_TTL` 60 s: entries stamped with `GetTime()`, dropped at the next NWB message, before the GUILD and own-message skips | "a stale partial message never assembles" (1); "a fresh partial message still assembles" holds on both sides |
| T4 | `me .. "-" .. GetNormalizedRealmName()` (line 393) threw when the realm name read nil. The event is registered at the button's OnShow, after login, so reachability is unverified: hardening | the player's name and realm are checked before the first concatenation; an unreadable one skips the message; the realm is passed on to `ProcessNWBMessage` | "a nil realm name doesn't throw", "and the message is skipped" (2) |

Not changed:
- Any message whose third field reads `x-N` counts as a report. Which NWB command carries it isn't
  verifiable on Forever and isn't a safety question.
- A damaged report can still parse (raw deflate has no checksum) and then reads as a report with another
  layer: an integer in range like any other, from a guild member. Nothing to do; the test says so.

Tests: `tests/nwb.lua` (44 checks) loads the four embedded libraries in plain Lua 5.1 (with WoW's string
aliases stubbed), builds real messages (`Serialize` → `CompressDeflate` → `EncodeForWoWAddonChannel`,
AceComm framing) and drives them through the registered event; the state is read the way a player reads
it, from `/titanlayer`'s "N guildies tracked, M layers seen" line. Run `lua tests/nwb.lua` from the addon
folder, like `tests/port.lua`. A lesson recorded there: LibDeflate's encoder returns two values, and the
second lands in the next argument of a call like `deliver(report(3))`.

## 3. In game

`/run print(tonumber("nan"), tonumber("inf"))` settles T1's condition on the client, for the record (the
fix doesn't depend on it; local Lua 5.1, an older MSVC runtime, gives `nil nil`).

_Result: pending the owner's session._
