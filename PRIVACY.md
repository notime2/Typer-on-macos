# Privacy

Typer On reads text you select in other applications and can replace it. That
is an unusual amount of access, so this document states exactly what happens
to your data. Everything below is verifiable in this repository.

## Short version

- Typer On has no backend. There is no Typer On server, account, or login.
- The only host the app ever contacts is `openrouter.ai` with your own API key,
  or, if you select the OpenAI-compatible provider, the endpoint you configured
  yourself - and only when you explicitly run a module or send a chat message.
- There is no telemetry, no analytics, no crash reporting, and no third-party
  SDK of any kind.

## What leaves your Mac

With the default OpenRouter provider, the app makes network requests to exactly
three endpoints, all on `openrouter.ai`:

| Endpoint | When | What is sent |
|----------|------|--------------|
| `POST /api/v1/chat/completions` | You run a module on selected text, or send a chat message | The system prompt, your text, and any attached screenshot |
| `POST /api/v1/images` | You send a chat message to a model with image output | The prompt and the latest session screenshot as an input reference |
| `GET /api/v1/models` | Settings opens the model catalog | Nothing but your key, to authorize the request |

Every request carries your OpenRouter API key as a `Bearer` token and an
`X-Title: Typer On` header, which is how OpenRouter attributes traffic to an
application. No other identifier is attached.

If you switch the provider in `Settings -> API` to **OpenAI-compatible (local)**,
`openrouter.ai` is not contacted at all. Requests go to the base URL you entered
and nowhere else: `POST {base URL}/chat/completions` when you run a module or
send a chat message, and `GET {base URL}/models` for the model list and for
**Test Connection**. No `X-Title` header is sent, an `Authorization: Bearer`
header is added only if you saved a key for that endpoint, and the OpenRouter
Images API is never used. Plain `http` is accepted only for local and
private-network addresses.

Once your text reaches OpenRouter, it is governed by
[OpenRouter's privacy policy](https://openrouter.ai/privacy) and by the
policy of whichever model provider you selected. Typer On has no visibility
into or control over that. If you process confidential material, choose your
model accordingly - OpenRouter exposes per-model data-retention settings in
your account.

Nothing is sent when the app is merely running. Auto-detecting a selection and
showing the floating toolbar happens entirely on-device; no network request is
made until you pick a module.

## What stays on your Mac

**API keys** are stored only in the macOS Keychain, through
`Security.framework`. They are never written to `UserDefaults`, to a config
file, or to logs. Per-module key overrides and the optional key for a local
endpoint live in the Keychain too - the settings store records only whether an
override exists.

**Settings** are in `UserDefaults` under the app's own domain: hotkey, default
language, the selected provider and its base URL, the selected model of each
provider, temperature and max tokens, enabled modules and their order, your
custom prompts, per-module configuration, cached model catalogs, window
size, and whether the chat history sidebar is shown. You can inspect them with
`defaults read com.typeron.app`.

**Selected text** is held in memory while it is captured. When you run a
module on it or use it as Chat context, it becomes part of that conversation in
the local chat history described below. Selected text that you only capture,
without running a module or sending a chat message, is not saved.

**Screenshots** captured in Chat Mode exist only as PNG data in memory. They
are never written to a file, never placed on the clipboard, and are discarded
when the session resets or the app quits. At most one pending screenshot is
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
requirement rather than a choice. Hardened Runtime is enabled.

## Verifying this yourself

This document describes the code in this repository, and you are encouraged to
check it rather than take it on faith:

```bash
grep -rE 'https?://' TyperOn/Sources --include='*.swift'
```

That should return `openrouter.ai` endpoints plus the `http://localhost:11434/v1`
and `http://localhost:1234/v1` examples shown in the local-endpoint settings, and
nothing else. Every other address comes from the base URL you type in
`Settings -> API`. Watching the app with Little Snitch, LuLu, or `nettop` will
show the same.
