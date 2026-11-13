# SandFly scripts

Lua scripts for the [SandFly](https://github.com/aaron-gh/SandFly) screen reader for Android. To use them, add this repository as a script source: in SandFly settings, go to **Apps** > **Scripts** > **Script sources** > **Add source**, and enter `github.com/aaron-gh/sandfly-scripts`. How to write scripts is in [Writing SandFly scripts](https://github.com/aaron-gh/SandFly/blob/master/docs/scripting.md).

| Script | App | Does | Author |
|---|---|---|---|
| `ai-reader.lua` | Gemini, Claude | Reads a reply once the app has finished writing it, including any code blocks. A port of Waypoint. | Devin Prater |
| `dialect-keypad.lua` | Dialect | Keys activate when the finger lifts, and long-press after a hold time. | Aaron Hewitt |
| `google-messages-actions.lua` | Google Messages | Pin, Mark as unread, Archive, Delete, Snooze, Block and Add contact are in each conversation's Actions menu. | Surendra |
| `keyboard-voice-gesture.lua` | All apps | While the keyboard is open, a two-finger double tap presses the keyboard's voice typing key. | Surendra |
| `openbubbles-messages.lua` | OpenBubbles | Each message in a chat is one item: sender, content, link preview, the message it replies to and its reply count. Dates are separate items and contact initials are left out. Mark Unread, Pin, Mute and Delete are in each conversation's Actions menu. | Aaron Hewitt |
| `whatsapp-messages.lua` | WhatsApp | Each message in a chat is one item: sender, content, the message it replies to, and time. Its buttons are in its Actions menu. | Aaron Hewitt |
| `youtube-actions.lua` | YouTube | Swiping skips the items in each video, mix, playlist, comment and reply. They are in its Actions menu. The keyboard shortcuts of YouTube on the desktop control the player. | Aaron Hewitt |

Each script ends with SandFly's signature, which SandFly checks before installing it: the install dialog says **Signed by SandFly.** for these scripts, wherever the file came from, and says so if a file was changed after signing. A changed script is signed again with `tools/sign_script.py` from the SandFly repository, which needs SandFly's signing key. SandFly updates these scripts without asking only when the new version is signed.

The scripts are under the Apache License 2.0. See [LICENSE](LICENSE).
