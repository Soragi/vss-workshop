# Workshop UI source

This is the repository-owned interface served at port 3100 and exposed through
the existing VSS ingress on port 7777. It has no Node, npm, or build step.

- `config.js` contains the attendee-facing workshop title.
- `index.html` defines the accessible screen structure.
- `app.css` contains the NVIDIA-aligned workshop layout and responsive rules.
- `app.js` contains the VSS integration. It reads the video list from VIOS,
  uploads short MP4 files through the VSS agent, and sends advisor prompts to
  the VSS Agent `/generate` endpoint.
- `nginx.conf` serves the static files without browser caching, so an updated
  deployment loads new workshop UI files immediately.

The browser makes same-origin requests only. Do not put NGC keys, credentials,
or private service addresses in these files.
