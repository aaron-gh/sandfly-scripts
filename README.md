# SandFly scripts

Lua scripts for the [SandFly](https://github.com/aaron-gh/SandFly) screen reader for Android. To use them, add this repository as a script source: in SandFly settings, go to **Apps** > **Scripts** > **Script sources** > **Add source**, and enter `github.com/aaron-gh/sandfly-scripts`. How to write scripts is in [Writing SandFly scripts](https://github.com/aaron-gh/SandFly/blob/master/docs/scripting.md).

| Script | App | Does |
|---|---|---|
| `dialect-keypad.lua` | Dialect | Keys activate when the finger lifts, and long-press after a hold time. |
| `whatsapp-messages.lua` | WhatsApp | Each message in a chat is one item: sender, content, the message it replies to, and time. Its buttons are in its Actions menu. |

The scripts are under the Apache License 2.0. See [LICENSE](LICENSE).
