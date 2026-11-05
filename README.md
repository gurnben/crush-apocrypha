# crush-apocrypha

Extensions to Crush that can't or won't make it upstream.

## Install a plugin

Crush plugin scripts are trusted Bash files that run at config load. Review a
plugin before installing it.

Because the scripts in this repository live under `plugins/`, install the ones
you want by copying them into Crush's plugin directory:

```bash
git clone https://github.com/gurnben/crush-apocrypha ~/.local/share/crush-apocrypha
mkdir -p ~/.config/crush/plugins
cp ~/.local/share/crush-apocrypha/plugins/*.sh ~/.config/crush/plugins/
chmod +x ~/.config/crush/plugins/*.sh
```

For a single project instead, copy the desired script into `.crush/plugins/` in
that project. Project plugins override global plugins.

## Google AI subscription plugin

`plugins/gemini-sub.sh` declares the Google AI subscription provider behind
Antigravity and Gemini CLI, including:

- OAuth browser login for `crush login gemini-sub`
- model discovery from the subscription gateway
- a gateway adapter for the internal Antigravity request/response format
- usage meters in `crush usage`
- `cld-*` and `gemini-*` model families served through the same subscription

This plugin requires a Crush build with provider-plugin support, including the
Google provider type and gateway adapters.

After installing the plugin:

```bash
crush login gemini-sub
crush models | grep '^gemini-sub/'
crush run -m gemini-sub/gemini-3.8-flash -q "Reply with the single word OK."
```

The plugin ships the shared Antigravity installed-app OAuth client id and
secret as defaults. Those are not personal credentials; account access comes
from the token stored by `crush login gemini-sub`. If you want to use a
different extracted client, export the values before starting Crush:

```bash
export CRUSH_ANTIGRAVITY_CLIENT_ID='...'
export CRUSH_ANTIGRAVITY_CLIENT_SECRET='...'
```
