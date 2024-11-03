# embed fixer

Fixes embeds in Discord. Check this out:

<img width="784" alt="Screenshot 2024-01-17 at 11 02 04 AM" src="https://github.com/deanveloper/embed-fixer/assets/3196327/99cf00f2-d259-4f30-8f21-c66fd95d5213">

Wow! Amazing!

Maps the following links:

| original | mapped |
| --- | --- |
| twitter.com | fxtwitter.com |
| x.com | fxtwitter.com |
| instagram.com | ddinstagram.com |
| reddit.com | rxddit.com |
| tiktok.com | tiktxk.com |

## Invite the bot to your server

https://embed-fixer.dean.day/

Requires the following permissions:
 * Read/Send Messages (so it can tell if a member posts a link, and reply with a fixed version of the URL)
   * Read/Send Messages in threads (same thing but for threads)
 * Embed (so it can embed)
 * Manage Messages (so it can remove the embed from the sender)
   * If you don't trust the bot, you can remove this permission. However, you may see double embeds on websites that have their own embeds (ie, tiktok)

## Hosting the bot yourself

```sh
zig build
TOKEN="yourtoken" ./embed-fixer
```
