# Wizard explanations — prose preface for every prompt

**Status:** Approved
**Date:** 2026-05-16
**Branch:** `feat/wizard-prose-explanations` (to be created)

## Goal

Make Dev Boxer's first-run wizard easier to follow by giving every prompt a short prose preface that explains what is being asked, why, and what to do — in plain language. Replace the seven existing labelled-bullet blocks (`What:` / `Why:` / `How:` / `Tip:` / `Cost:` / `Link:`) with the same prose style so the whole wizard reads consistently.

## Motivation

Today the wizard's explanations are uneven. The Cloudflare-related steps get a lot of care — multi-line labelled blocks that cover background, scope, alternatives, and cost. Half the other prompts have no preface at all, so the user is asked for a value with no context (Linux username, SSH key, SSH port, Matrix `here` vs `there`, Matrix username, the add-bot blob, Claude experience level). The mix between rich labelled blocks and bare prompts is jarring.

The labelled-bullet format itself feels checklist-y when prose would read more naturally. Switching to prose paragraphs both fills the gaps and improves the parts that already had explanations.

## Approach

A single-file change in `lib/dev_boxer/wizard.rb`:

- Each prompt gets a small `explain_*` method that emits a short prose paragraph before the prompt runs.
- The seven existing `explain_*` methods are rewritten in the same prose style.
- The inline three-line Claude-behavior summary is moved into a proper `explain_claude_experience_level` method.
- Each prose paragraph is two to four sentences, plain language, with any essential URL inlined into the prose rather than appended as a separate line.

No new files, no new abstractions, no flag toggles. The existing `output.puts` / `explain_*` pattern is good enough — we are improving the copy and filling gaps, not restructuring the wizard.

## Style guidelines

- One paragraph per prompt; two to four sentences is the target. Aim shorter rather than longer.
- Plain language. No labelled bullets like `What:` / `Why:` / `How:`. Cut `Tip:` / `Cost:` / `Link:` garnishes unless the information is critical.
- Mention what is being asked, why it matters, and the actionable bit (a sensible default, a command, a URL). Inline a URL into a sentence if it is essential; drop it otherwise.
- Keep the existing tone: friendly, concrete, second person.
- Punctuation style matches the rest of the codebase — sentence case, US spelling, ASCII dashes, no oxford comma policing.

## Inventory

Every prompt the wizard asks. Existing prefaces are converted; missing ones are added.

| # | Prompt | Currently | Action |
|---|---|---|---|
| 1 | Linux username | none | new prose |
| 2 | SSH public key | none | new prose |
| 3 | SSH port | none | new prose |
| 4 | Base domain | labelled bullets | rewrite to prose |
| 5 | Cloudflare zone DNS token | labelled bullets | rewrite to prose |
| 6 | Manual DNS notice | labelled bullets | rewrite to prose |
| 7 | Cloudflare automation | labelled bullets | rewrite to prose |
| 8 | Manual Access after manual DNS | labelled bullets | rewrite to prose |
| 9 | Manual Cloudflare setup | labelled bullets | rewrite to prose |
| 10 | One-time Cloudflare setup token | labelled bullets | rewrite to prose |
| 11 | Matrix `here` vs `there` | none | new prose |
| 12 | Matrix username | none | new prose |
| 13 | Add-bot blob paste | none | new prose |
| 14 | Claude experience level | inline 3-line summary | move into `explain_*`, rewrite to prose |

(Two prompts in the wizard — the inner `confirm` calls inside choose-cloudflare-setup — share their preface with the preceding `explain_*` block and are not separate items above.)

## Sample voice

Two examples to lock in the tone. Implementation will follow this register for every prompt.

**Linux username** (new):
> The Linux account you'll ssh into and do your work as. `dev` is fine if you don't have a preference; just avoid `root` — Dev Boxer disables root login regardless.

**Cloudflare zone DNS token** (rewrite of existing block):
> Dev Boxer needs a zone-scoped API token for `example.com` so it can create and update DNS records for `dev`, `matrix`, `viewer`, `hello`, and any project subdomains you make later. Create one at https://dash.cloudflare.com/profile/api-tokens with `Zone:Read` and `DNS:Edit` scoped to this zone only — never all zones. Choose no below if you'd rather create each subdomain manually.

## Code shape

All changes live in `lib/dev_boxer/wizard.rb`:

- Add six new private `explain_*` methods: `explain_linux_username`, `explain_ssh_public_key`, `explain_ssh_port`, `explain_matrix_location`, `explain_matrix_username`, `explain_add_bot_blob`.
- Rewrite the seven existing `explain_*` methods to prose: `explain_base_domain`, `explain_cloudflare_zone_token`, `explain_manual_dns_setup`, `explain_manual_access_after_manual_dns`, `explain_cloudflare_automation`, `explain_manual_cloudflare_setup`, `explain_cloudflare_setup_token`.
- Add `explain_claude_experience_level` and replace the inline three-line block currently in `build_claude_config`.
- Wire each new method into the corresponding prompt site by inserting a single `output.puts` then `explain_<topic>` line before the matching `ask(...)` / `ask_choice(...)` / `confirm(...)` call.

No method signatures change outside of the new private methods. No public API impact.

## Tests

`test/wizard_test.rb` asserts on specific strings in the rendered output, e.g. `"Scope: Limit the token to the example.com zone only. Do not grant access to all zones."` Those assertions will fail when the copy changes. The fix:

- Update each affected `assert_includes` to match the new prose. The substring chosen should be a stable, distinctive phrase from the new paragraph — not a full sentence (which would be too brittle).
- Add a handful of new `assert_includes` assertions for the six previously-uncovered prefaces (username, SSH key, SSH port, Matrix `here` vs `there`, Matrix username, add-bot blob) so future regressions on the new prefaces get caught.

Net change: roughly five new assertions, no new test methods.

## Out of scope (YAGNI checks)

- Progress indicators ("step 2 of 5").
- Adaptive depth that scales explanations by `claude.experience_level`.
- Moving the prose to a separate copy file or YAML.
- i18n / translation hooks.
- Restructuring the wizard flow itself or changing prompt order.

If we later want any of these, they can be added on top of this change without rework.
