---
name: writing-rules
description: This skill should be used when the user asks to "write a PR title", "write a PR description", "draft a PR body", "write an MR description", "write a GitHub comment", "write an issue comment", "reply to this review", "draft a Basecamp comment", "rewrite this for Basecamp", "write a ticket update", "write a Slack message", "draft an email", "write a commit message", "prepare release notes", "rewrite this text", "polish this message", "improve wording", "word this better", "make this sound human", "edit this message", "draft a reply", or whenever preparing text that will be posted, committed, emailed, messaged, or sent to another human via CLI tools.
---

# Writing Rules

Apply these rules to human-facing text that leaves Claude Code through a tool call.

## When to Use

Use this skill for text that will be read by another human outside the current Claude Code chat. Common cases:

- GitHub pull request titles and bodies
- GitHub review comments, issue comments, and replies
- Chat, forum and project-tool posts (Slack, Basecamp, Discord, issue trackers)
- Emails
- Commit messages and annotated git tags
- Release notes and similar published summaries
- Rewrites of pasted text when the user wants clearer wording

Do not apply this skill to normal chat replies to the user, internal status updates between tool calls, code comments, test fixtures, or raw log output.

## Boundary Rule

Check whether the string is about to leave Claude Code and land in front of another human through a tool call. If yes, apply this skill.

Apply the skill even when drafting the text in chat first and posting it later through a tool. The destination matters more than where the draft was written.

## Language

- A reply is written in the language of the message it answers: English to an English chat line, Russian to a Russian comment. Check the original before drafting. Never default to a language because other text in the same place uses it.
- A new post (a card, a comment that starts a thread, a PR text) follows the language of the place it goes to. When that is unclear, ask the user which language before drafting.
- PR titles, PR bodies, review comments and commit messages are English.
- Add-ons may set a standing exception for a destination. Follow it.

## Core Style Rules

Follow these rules in every final draft:

- Never use em dashes or en dashes. Use periods or restructure the sentence.
- Never use semicolons. Split the thought into separate sentences.
- Never use non-ASCII symbols in prose. Use plain ASCII equivalents.
- Minimize comma usage.
- Never open a reply with praise for the question or the asker, such as "good question", "great point" or "thanks for the great question". It is filler. Start with the answer. The only exception is a question that genuinely and deeply surprised you.
- On GitHub a bare `#N` links to PR or issue N of the current repo. Write a PR or issue in another repo as `owner/repo#N` (e.g. `octo-org/shared#1002`) or as the full URL. Never write "shared #1002". This applies to PR bodies, review comments, replies and commit messages.
- For short comments such as GitHub review comments or short forum-style replies, start with a lowercase letter and omit the trailing period.
- Never hard wrap prose to a column width. Keep each paragraph on one continuous line and let the destination wrap it. Insert a line break only where a line break is actually wanted, such as between paragraphs or between list items. This applies to the draft shown in chat as well as the final string, because the draft is usually the thing that gets sent. Destinations such as Basecamp or Slack treat every newline as a real line break, so a wrapped paragraph arrives broken across lines.

## Rewriting Pasted Text

When rewriting pasted text, keep the meaning and point of view intact.

- Preserve ideas, claims, tense, person, and intent.
- Keep roughly the same length and structure unless the structure itself is one of the banned patterns.
- Do not invent stories, numbers, promises, or certainty.
- Make the text sound like a clear specific human. Avoid generic AI voice.

## Banned Language

Treat these bans as hard constraints for final human-facing output.

### Voice

When rewriting pasted text, make it read like a clear, specific human. Not like ChatGPT, Claude, or a generic AI voice.

- Preserve content. Change only the voice.
- Keep ideas, claims, POV, tense, and person.
- Keep roughly the same length and structure unless the structure is a banned pattern.
- Do not invent stories, numbers, or promises.

### Banned Words

Must not appear in final output:

delve, realm, harness, unlock, tapestry, paradigm, cutting-edge, revolutionize, landscape, potential, findings, intricate, showcasing, crucial, pivotal, surpass, meticulously, vibrant, unparalleled, underscore, leverage, synergy, innovative, game-changer, testament, commendable, meticulous, highlight, emphasize, boast, groundbreaking, align, foster, showcase, enhance, holistic, garner, accentuate, pioneering, trailblazing, unleash, versatile, transformative, redefine, seamless, optimize, scalable, robust, breakthrough, empower, streamline, intelligent, smart, next-gen, frictionless, elevate, adaptive, effortless, data-driven, insightful, proactive, mission-critical, visionary, disruptive, reimagine, agile, customizable, personalized, unprecedented, intuitive, leading-edge, synergize, democratize, automate, accelerate, state-of-the-art, dynamic, reliable, efficient, cloud-native, immersive, predictive, transparent, proprietary, integrated, plug-and-play, turnkey, future-proof, open-ended, AI-powered, next-generation, always-on, hyper-personalized, results-driven, machine-first, paradigm-shifting

### Banned Expression Patterns

#### A) In a world where drama

Formula: "In a world where [scary change], [virtue] becomes [currency]."

Use instead:
- Today, [specific change]. So [practical implication].
- Because [concrete change], do [specific action] to get [specific result].

#### B) Most people vs few who split

Formula: "Most people [lazy thing]. The few who win [disciplined thing]."

Use instead:
- Among [group], [specific stat or observation]. What works: [one tactic].
- Personal stance: I do [specific practice] to avoid [specific downside].

#### C) Stop doing X. Start doing Y. switch

Formula: "Stop [old habit]. Start [new habit]."

Use instead:
- If you're doing [X], switch to [Y] when [condition], because [reason].
- Replace [X] with [Y]: [1-3 concrete steps the reader can take].

#### D) Praise opener

Formula: "[Good / Nice / Great] question[s], [answer]." or "Excellent point. [answer]."

Use instead:
- [answer] with nothing in front of it.
- "good questions, these steps run on two machines" becomes "these steps run on two machines".

## Practical Workflow

1. Identify the destination of the text.
2. Decide whether the destination is human-facing outside Claude Code.
3. Draft the text in direct plain language.
4. Check punctuation and ASCII constraints.
5. Check short-comment casing when applicable.
6. Check the banned words and banned patterns in this file. Remove anything that violates them.
7. Only then send the text through the tool call.

## Short Comment Rule

Use the short comment rule only for brief comments and replies. Do not force lowercase openings on PR titles, issue titles, PR bodies, or longer structured writeups.

## Add-ons and priority

A project or company can extend these rules with an add-on skill: extra destinations, language exceptions, house formats. When your instructions name one, load it together with this skill and apply both. An add-on wins where it is more specific.

If another project instruction defines content requirements for a specific destination, satisfy both sets of rules. Keep the writing rules unless they directly conflict with a higher-priority instruction.