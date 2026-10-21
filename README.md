# SandFly scripts

Lua scripts for the [SandFly](https://github.com/aaron-gh/SandFly) screen reader for Android. To use them, add this repository as a script source: in SandFly settings, go to **Apps** > **Scripts** > **Script sources** > **Add source**, and enter `github.com/aaron-gh/sandfly-scripts`. How to write scripts is in [Writing SandFly scripts](https://github.com/aaron-gh/SandFly/blob/master/docs/scripting.md).

| Script | App | Does | Author |
|---|---|---|---|
| `dialect-keypad.lua` | Dialect | Keys activate when the finger lifts, and long-press after a hold time. | Aaron Hewitt |
| `google-messages-actions.lua` | Google Messages | Pin, Mark as unread, Archive, Delete, Snooze, Block and Add contact are in each conversation's Actions menu. | Surendra |
| `keyboard-voice-gesture.lua` | All apps | While the keyboard is open, a two-finger double tap presses the keyboard's voice typing key. | Surendra |
| `whatsapp-messages.lua` | WhatsApp | Each message in a chat is one item: sender, content, the message it replies to, and time. Its buttons are in its Actions menu. | Aaron Hewitt |
| `youtube-actions.lua` | YouTube | Swiping skips the buttons in each video, mix, playlist and comment. They are in its Actions menu. | Surendra |

The scripts are under the Apache License 2.0. See [LICENSE](LICENSE).
