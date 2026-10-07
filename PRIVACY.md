# Privacy

Typer On reads text you select in other applications and can replace it. That
is an unusual amount of access, so this document states exactly what happens
to your data. Everything below is verifiable in this repository.

## Short version

- Typer On has no backend. There is no Typer On server, account, or login.
- Direct AI HTTP requests go to `openrouter.ai` with your API key, or to your
  configured OpenAI-compatible endpoint. If you select Codex or Claude Code,
  the installed official CLI handles authentication and sends requests to
  OpenAI or Anthropic services using your subscription.
- Your text and screenshots are sent only when you explicitly run a module or
  send a chat message. The app also fetches the model list and model metadata
  in the background, or checks the subscription CLI's account and models;
  those checks contain no text, prompts, or screenshots.
- Update checks go to `github.com`, only after you allow them, and send nothing
  but the app and framework versions. See [Update checks](#update-checks).
- There is no telemetry, no analytics, and no crash reporting. The only
  third-party app dependency is the open-source [Sparkle](https://sparkle-project.org)
  update framework. Codex and Claude Code are separately installed programs
  with their own network, storage, and diagnostic behavior.

## What leaves your Mac

With the default OpenRouter provider, the app makes network requests to exactly
four endpoints, all on `openrouter.ai`:

| Endpoint | When | What is sent |
|----------|------|--------------|
| `POST /api/v1/chat/completions` | You run a module on selected text, or send a chat message | The system prompt, your text, and any attached screenshot |
| `POST /api/v1/images` | You send a chat message to a model with image output | The prompt and the latest session screenshot as an input reference |
| `GET /api/v1/models` | At launch if a global API key is saved; again after you save `Settings -> API \ Models`, save or clear the key from the status bar, or pick a model in the status bar `Model` menu; and when you press refresh in a model picker | Nothing but your key, to authorize the request |
| `GET /api/v1/model/{author}/{slug}` | Chat Mode only, when the loaded model list has no complete entry for the Chat model (for example a manually entered model ID, or before the list has loaded): when the Chat window opens, when the model list or AI settings change while it is open, before a screenshot is captured, and before a message or retry is sent in a conversation that contains a screenshot. The result is kept in memory for the session | Your key, plus the model ID in the URL path |

The two `GET` requests have no request body. They never include selected text,
prompts, chat history, or screenshots. A refresh in `Settings -> API \ Models` uses the
key currently in the key field; a refresh in a module's model picker uses the
key entered or saved for that module, otherwise the global key. Model metadata
is requested with the key of the `Chat Mode` module configuration.

Every request carries your OpenRouter API key as a `Bearer` token and two
attribution headers, `X-Title: Typer On` and
`HTTP-Referer: https://github.com/notime2/Typer-on-macos`, which is how
OpenRouter attributes traffic to an application. Both values are the same for
every install. No other identifier is attached.

If you switch the provider in `Settings -> API \ Models` to **OpenAI-compatible (local)**,
`openrouter.ai` is not contacted at all. Requests go to the base URL you entered
and nowhere else: `POST {base URL}/chat/completions` when you run a module or
send a chat message, and `GET {base URL}/models` for the model list. The model
list is requested at launch and after the same configuration changes as above
whenever a valid base URL is saved (a key is optional), when you press refresh
in a model picker, and by **Test Connection**, which requests it once for the
check and once more to fill the list after a successful check. That `GET`
carries no text and no body. Per-model metadata is never requested from a local
endpoint. No OpenRouter attribution headers are sent, an `Authorization: Bearer`
header is added only when a key is entered or saved for that endpoint, and the
OpenRouter Images API is never used. Plain `http` is accepted only for local and
private-network addresses.

### Codex and Claude Code subscriptions

When Codex or Claude Code is selected, Typer On launches that official CLI
instead of making an OpenRouter or local-endpoint AI request. The CLI owns
sign-in and its connections to OpenAI or Anthropic authentication and AI
services. Those destinations depend on the installed CLI and service
configuration; the app's HTTP endpoint table does not describe all traffic
from the child process.

When you run a built-in or custom module, send a chat message, refine a
response, or request screenshot analysis, Typer On passes the applicable
system prompt, text history, and attached screenshot to the selected CLI.
User messages and screenshots use the process's standard input; Claude Code's
system prompt is a direct process argument. Neither path uses shell interpolation.
Connection and model-catalog checks pass no user content. Typer On does not
read, store, or log the CLI's OAuth tokens. Global and module API keys remain
in Keychain and are not used for subscription requests. Inherited API-key and
alternate-provider environment variables are removed from child CLI launches
so subscription requests do not use those API credentials.

The integrations disable agent tools and request responses without access
to your files or shell. Image generation is unavailable through these CLI
integrations: the app shows that limitation and suggests choosing OpenRouter
manually. Errors and unsupported capabilities do not trigger an automatic
provider switch.

OpenAI's or Anthropic's account terms, usage limits, and data policies apply
to content sent through their CLIs. Typer On requests a fresh ephemeral Codex
conversation and disables Claude Code session persistence. Each child runs
in a private temporary working directory that is removed when it exits;
Typer On does not write screenshot or request files there. These controls do
not govern provider retention or all CLI diagnostics. CLI storage and diagnostics
are separate from Typer On's local history and unified logging described below.

Once your text reaches OpenRouter, it is governed by
[OpenRouter's privacy policy](https://openrouter.ai/privacy) and by the
policy of whichever model provider you selected. Typer On has no visibility
into or control over that. If you process confidential material, choose your
model accordingly - OpenRouter exposes per-model data-retention settings in
your account.

Auto-detecting a selection and showing the floating toolbar happen entirely
on-device and never make a network request, and no text leaves your Mac until
you run a module or send a chat message. The app is not network-idle before
that, though: the model-list, model-metadata, and subscription connection
checks described above can run before a prompt is sent. HTTP discovery carries
at most your API key (and, for metadata, the model ID). Update
checks, once you allow them, are described next.

## Update checks

Typer On updates itself with [Sparkle](https://sparkle-project.org). It does
not check for updates until you agree: on the second launch Sparkle asks
whether to check automatically. After that:

| Request | When | What is sent |
|---------|------|--------------|
| `GET https://github.com/notime2/Typer-on-macos/releases/latest/download/appcast.xml` | Once a day if automatic checks are on, and whenever you choose **Check for Updates...** in the menu bar | Nothing but a `User-Agent` with the Typer On and Sparkle versions |
| The DMG of a newer release on `github.com` | Only when an update is installed | The same `User-Agent` |

GitHub redirects both downloads to its release-asset host. Sparkle's optional
system profile (macOS version, CPU, and similar) is not enabled, so no hardware
or system details are sent. Your text, keys, and settings are never part of an
update request. Each update is verified with an EdDSA signature and must carry
the same code signature as the installed app before Sparkle installs it.

Turn off **Automatically check for updates** or **Automatically download and
install updates** in **Settings -> General** at any time. The diagnostic
`--qa-stream-replay` mode never checks for updates.

## What stays on your Mac

**API keys** are stored only in the macOS Keychain, through
`Security.framework`. They are never written to `UserDefaults`, to a config
file, or to logs. Per-module key overrides and the optional key for a local
endpoint live in the Keychain too - the settings store records only whether an
override exists.

**Subscription authentication** belongs to the installed Codex or Claude Code
CLI. Typer On saves its executable path and model choice, not its login
tokens. Signing in uses the official CLI's authentication flow and storage.

**Settings** are in `UserDefaults` under the app's own domain: hotkey, default
language, the selected provider, its base URL or CLI executable path, each
provider's selected model, temperature and max tokens, enabled modules and their order, your
custom prompts, per-module configuration, cached model catalogs, window
size, and whether the chat history sidebar is shown. You can inspect them with
`defaults read com.typeron.app`.

**Selected text** is held in memory while it is captured. When you run a
module on it or use it as Chat context, it becomes part of that conversation in
the local chat history described below. Selected text that you only capture,
without running a module or sending a chat message, is not saved.

**Screenshots** captured in Chat Mode exist only as PNG data in Typer On's
memory. Typer On never writes them to a file or places them on the clipboard;
they are discarded when the session resets or the app quits. At most one pending screenshot is
kept.

**Chat history.** Chat Mode conversations and every module run (the selected
text, each result, and your refinement instructions) are saved to
`~/Library/Application Support/Typer On/chat-history.json` on your Mac. The
file is never uploaded or synced by Typer On, keeps at most the 500 most recent
conversations, and contains text only: screenshots and generated images are not
stored and show as "Image unavailable" when a chat is reopened. Delete single
chats or everything in **Settings -> Chat History -> Clear All**, or remove the
file. The diagnostic `--qa-stream-replay` mode keeps history in memory only.

## Logging

Typer On logs through Apple's unified logging (`os.Logger`). Logs stay on your
machine and are visible in Console.app.

Capture logging is deliberately metadata-only: it records UTF-16 length,
process ID, bundle identifier, capture confidence, and which accessibility
evidence source won - never the selected text itself. API keys, request
bodies, image bytes, and base64 data URLs are not logged.

This describes Typer On's logs, not diagnostics maintained by a separately
installed Codex or Claude Code CLI. Consult that CLI's settings and policies
for its own local storage and diagnostic behavior.

## System permissions

**Accessibility** is required and is the core of the app. It is used to read
the current selection from the focused element in other applications, resolve
its on-screen bounds so the toolbar can be positioned, and write the replaced
text back. macOS grants this per-application; you can revoke it at any time in
System Settings, and Typer On detects the change and stops auto-detection.

**Screen Recording** is requested by macOS only at the moment you choose to
attach an area, window, or display in Chat Mode. If you never use screenshots,
it is never requested. Capture goes through ScreenCaptureKit; the app has no
ability to capture in the background.

**Clipboard** is used as a fallback path when direct accessibility replacement
is not possible. In that case Typer On snapshots the full pasteboard, performs
the copy or paste, and restores the previous contents - including empty and
non-text states. It does not read your clipboard otherwise, and does not keep
a clipboard history.

## Sandboxing

Typer On is not sandboxed (`ENABLE_APP_SANDBOX: NO`). The Accessibility APIs it
depends on are unavailable to sandboxed applications, so this is a technical
requirement rather than a choice. Hardened Runtime is enabled with library
validation turned off: release builds are signed with a self-signed identity
that has no Apple Team ID, and library validation would otherwise refuse to
load the embedded Sparkle framework.

## Verifying this yourself

This document describes the code in this repository, and you are encouraged to
check it rather than take it on faith:

```bash
rg -n 'https?://' TyperOn/Sources -g '*.swift'
```

That search shows `openrouter.ai` URLs under `/api/v1` (the API base, the
endpoints from the table above, and the `/api/v1/model` prefix of the per-model
metadata URL), the `http://localhost:11434/v1` and `http://localhost:1234/v1`
examples shown in the local-endpoint settings, and
`https://github.com/notime2/Typer-on-macos`, which is the value of the
`HTTP-Referer` header, not a host the app contacts. The update feed is the
`SUFeedURL` value in `TyperOn/project.yml`, and the local AI endpoint comes
from the base URL you type in `Settings -> API \ Models`.
Documentation URLs in code comments do not themselves establish network traffic.

That source search cannot enumerate connections opened by Codex or Claude
Code. Inspect [the subscription transport](TyperOn/Sources/AI/SubscriptionAIService.swift)
and [CLI setup](TyperOn/Sources/AI/SubscriptionCLI.swift) alongside the HTTP transport,
and include child processes when watching network activity with Little
Snitch, LuLu, or `nettop`. Update downloads can also follow GitHub redirects
to its release-asset host, as described above.
