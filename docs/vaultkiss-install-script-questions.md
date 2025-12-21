# vaultKISS Install Script Feature Questions for the Original Designer

This document collects clarifying questions about the proposed **`/api/install` + install script** feature, so that another AI (or future you) can refine the design before implementation.

---

## 1. Token exposure & logging

The current design uses a URL like:

```bash
curl -sf "https://vaultkiss.netlify.app/api/install?token=THEIR_TOKEN" | bash
```

Questions:

1. Are we comfortable with the **raw app token** appearing in:
   - Shell history (`~/.bash_history`),
   - Logs (CI logs, copy-paste into tickets),
   - Browser history (if opened interactively)?

2. Do we want to **document a safer pattern** as the preferred usage, e.g.:

   ```bash
   export VAULTKISS_TOKEN=...   # maybe pasted once from the UI
   curl -sf "https://vaultkiss.netlify.app/api/install?token=${VAULTKISS_TOKEN}" | bash
   unset VAULTKISS_TOKEN
   ```

3. From a docs/UX perspective, should we:
   - Show only the **simple one-liner** with `?token=...`,
   - Or show **both** (simple + safer) and explain trade-offs?

---

## 2. Template name → filename mapping

The spec says scripts are stored as:

- Bucket: `install-scripts`
- Object path: `install-scripts/autolift-api.sh` (matching template name),
- Endpoint uses: `download(`${templateName}.sh`)`.

Questions:

1. Are template names **guaranteed to be valid filenames**?
   - Do we allow spaces, slashes, non-ASCII characters, etc. in `templates.name`?
   - If yes, how should we map template names to storage object names safely?

2. Should we introduce a **separate, stable slug** for templates, e.g.:
   - `templates.slug` (e.g. `autolift-api`),
   - Use `slug` for file paths (`${slug}.sh`) and keep `name` free-form for UI?

3. Is the intended model strictly **1 install script per template**?
   - All apps using template `autolift-api` share the same `autolift-api.sh`.
   - Or do we foresee variants like `autolift-api-ubuntu.sh`, `autolift-api-alpine.sh`?

If multiple variants per template are likely, we might want a naming convention or additional metadata to distinguish them.

---

## 3. Where does the script live from the users POV?

Right now the spec assumes **manual upload** to Supabase Storage:

- Developer/maintainer uploads `autolift-api.sh` into the `install-scripts` bucket.

Questions:

1. What is the intended workflow long term?
   - a) You (maintainer) hand-craft each `install-*.sh` and upload via Supabase UI,
   - b) There is/will be a **vaultKISS UI** for managing scripts per template (upload, edit, versioning),
   - c) Scripts will be **generated** by vaultKISS based on template metadata and some additional configuration.

2. Should the vaultKISS UI expose an **"Install" snippet** per app or template, e.g. on the app detail page:

   ```bash
   curl -sf "https://vaultkiss.netlify.app/api/install?token=APP_TOKEN" | bash
   ```

   - If yes, where should that live (apps page, template page, both)?

---

## 4. Token in query param vs Authorization header

Today:

- `/api/secrets` uses `Authorization: Bearer <token>`.
- The proposed `/api/install` uses `?token=<token>`.

Questions:

1. Is this **difference intentional** for UX reasons (easier curl one-liners)?

2. Should `/api/install` also support **`Authorization: Bearer <token>`** as an alternative, so that:
   - Automated systems / CI / agents can avoid putting tokens in URLs,
   - We keep auth style more consistent across endpoints.

3. If we do support both, do we have an order of precedence (header vs query param) or do we require exactly one?

---

## 5. Responsibilities & contract of `install.sh`

The spec leaves the contents of `install.sh` mostly open. It could:

- Install Docker / Docker Compose,
- Clone an infra repo,
- Write `docker-compose.yml` and `.env`,
- Start containers via `docker compose up -d`,
- Or something else.

Questions:

1. Do you have a **minimum contract** for what every `install-*.sh` should do?
   - Example: "Given a clean VPS, run this and end up with the app running in Docker."

2. Should vaultKISS eventually **generate a base script** (e.g. all the `/api/secrets` and Docker wiring) and allow the maintainer to graft custom logic on top?
   - Or is the current plan to keep scripts entirely **user-authored** and vaultKISS just handles token injection?

3. How much do we want scripts to be **stable across environments** (e.g. Ubuntu vs Alpine vs other distros)?
   - If differences are expected, should we plan for multiple script variants per template (see section 2)?

---

## 6. Safety, rate limiting, and observability

`/api/install?token=...` is extremely convenient and also very guessable.

Questions:

1. Do we need any **rate limiting** or abuse protection on `/api/install`?
   - If a token leaks, someone could hammer this endpoint.
   - Are we okay with that as long as tokens can be rotated, or do we want basic throttling per token/IP?

2. Should we log **install events** in a small table (e.g. `app_install_events`):
   - `app_id`, `token_hash`, `timestamp`, maybe `ip_hash` or user agent,
   - For debugging and observability ("who ran install, when?").

3. Do we want any built-in safeguard around script size or type (e.g. ensure `text/x-shellscript`, cap maximum size) to prevent misuse of the bucket as a generic file host?

---

## 7. Placeholder semantics inside the script

Current spec for placeholder in the script:

```bash
VAULTKISS_TOKEN="{{VAULTKISS_TOKEN}}"

if [ "$VAULTKISS_TOKEN" = "{{VAULTKISS_TOKEN}}" ]; then
    error "Token not embedded - script was not fetched correctly"
fi
```

Questions:

1. Do we want a **canonical placeholder name** and format beyond just `{{VAULTKISS_TOKEN}}`?
   - e.g. `{{ VAULTKISS_TOKEN }}` vs `{{VAULTKISS_TOKEN}}` vs `${VAULTKISS_TOKEN}`.
   - Should we support additional placeholders (e.g. template name, app name, vaultKISS URL)?

2. Shell detail: plain `sh` does not have a built-in `error` function.
   - Should the canonical snippet use something like:

     ```bash
     echo "Token not embedded - script was not fetched correctly" >&2
     exit 1
     ```

   - Or do you expect scripts to define their own `error()` helper before this block?

3. Do we foresee **multiple replacements** (e.g. token in several places), and are we okay with a simple global string replace, or do we need something more structured?

---

These answers will help finalize the design of `/api/install`, the storage layout for scripts, and the user-facing documentation/UX in vaultKISS.

