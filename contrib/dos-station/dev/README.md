# DOS Station dev harness

Develop and test `../plugins/dos_station.html` in a desktop browser, outside
Note Synapse, against a stubbed Synapse API.

```bash
cd contrib/dos-station
python3 -m http.server 8471
# open http://localhost:8471/dev/test_harness.html
```

- `synapse_stub.js` — fake `window.Synapse` covering the API surface DOS
  Station uses. `proxyFetch` proxies to real `fetch` (the js-dos CDN is
  CORS-enabled), app state persists in `localStorage`, and note mutations are
  shown in the harness log panel, including the app's uuid-style attachment
  renaming so the capture-append path is exercised realistically.
- `test_harness.html` — loads the plugin into an iframe with the stub
  injected first, plus a live Synapse-call log.
- `testgame.zip` — a fake "game": a hand-assembled `HELLO.COM` (prints a
  banner via int 21h), `PLAY.BAT`, `README.TXT` — enough to verify mount,
  launcher ranking, autoexec, and the DOS prompt.

None of this folder is part of the installable plugin.
