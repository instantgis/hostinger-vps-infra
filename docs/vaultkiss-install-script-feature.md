# vaultKISS: Add Install Script Support

## Overview

Add the ability to serve an install script per template via Supabase Storage. When a customer hits `/api/install` with their token, they get the install.sh with their token pre-embedded.

## 1. Supabase Storage Setup

Create a storage bucket for install scripts in Supabase Dashboard > SQL Editor:

```sql
INSERT INTO storage.buckets (id, name, public) 
VALUES ('install-scripts', 'install-scripts', false);

CREATE POLICY "Service role only" ON storage.objects
FOR SELECT USING (bucket_id = 'install-scripts' AND auth.role() = 'service_role');
```

Upload script as: `install-scripts/autolift-api.sh` (matching template name)

## 2. New API Endpoint

Create `src/routes/api/install/+server.ts`:

```typescript
import { error } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { hashToken } from '$lib/server/utils';

export const GET: RequestHandler = async ({ url, locals }) => {
    const token = url.searchParams.get('token');
    if (!token) {
        throw error(400, 'Missing token parameter');
    }

    const { data: app, error: appError } = await locals.supabaseAdmin
        .from('apps')
        .select('id, name, template:templates(name)')
        .eq('token_hash', hashToken(token))
        .single();

    if (appError || !app) {
        throw error(401, 'Invalid token');
    }

    const templateName = app.template?.name;
    if (!templateName) {
        throw error(404, 'Template not found');
    }

    const { data: scriptData, error: storageError } = await locals.supabaseAdmin
        .storage
        .from('install-scripts')
        .download(`${templateName}.sh`);

    if (storageError || !scriptData) {
        throw error(404, 'Install script not found for this template');
    }

    let script = await scriptData.text();
    script = script.replace(/\{\{VAULTKISS_TOKEN\}\}/g, token);

    return new Response(script, {
        headers: {
            'Content-Type': 'text/x-shellscript',
            'Content-Disposition': 'attachment; filename="install.sh"'
        }
    });
};
```

## 3. Install Script Token Placeholder

The install.sh must use this placeholder near the top:

```bash
VAULTKISS_TOKEN="{{VAULTKISS_TOKEN}}"

if [ "$VAULTKISS_TOKEN" = "{{VAULTKISS_TOKEN}}" ]; then
    error "Token not embedded - script was not fetched correctly"
fi
```

## 4. Customer Usage

```bash
curl -sf "https://vaultkiss.netlify.app/api/install?token=THEIR_TOKEN" | bash
```

## 5. Testing

1. Upload test script to `install-scripts/autolift-api.sh` with content: `echo "Token: {{VAULTKISS_TOKEN}}"`
2. GET `/api/install?token=<valid-token>`
3. Verify token is embedded in response

