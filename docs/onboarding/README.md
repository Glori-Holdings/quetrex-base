# Quetrex onboarding

`quetrex-new-user-setup.pdf` — the hand-out guide for new users (machine + per-repo setup, commands, board lifecycle, roles/access, admin tasks).

Source: `quetrex-new-user-setup.html`. Regenerate the PDF after editing the HTML:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --no-pdf-header-footer \
  --print-to-pdf=docs/onboarding/quetrex-new-user-setup.pdf \
  "file://$PWD/docs/onboarding/quetrex-new-user-setup.html"
```
