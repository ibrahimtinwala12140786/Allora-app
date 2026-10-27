// @ts-nocheck
// Allora Instagram Webhook Edge Function
// Handles Meta Webhook Verification (GET) and Instagram Direct Messaging Events (POST)
// Direct integration without Matrix bridges.

import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const DEFAULT_VERIFY_TOKEN = "allora_the_universal_messaging_app";

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);

  // 1. Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_ANON_KEY") || "";
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  // ─── 2. GET REQUEST: META WEBHOOK VERIFICATION ──────────────────────────
  // Meta sends a GET request when clicking "Verify and save" in Developer Portal:
  // hub.mode = "subscribe"
  // hub.verify_token = token entered in portal
  // hub.challenge = string to echo back
  if (req.method === "GET") {
    const mode = url.searchParams.get("hub.mode");
    const token = url.searchParams.get("hub.verify_token");
    const challenge = url.searchParams.get("hub.challenge");

    console.log(`[Meta Webhook GET] mode=${mode}, token=${token}, challenge=${challenge}`);

    const expectedToken = Deno.env.get("INSTAGRAM_VERIFY_TOKEN") || DEFAULT_VERIFY_TOKEN;

    if (mode === "subscribe" && token === expectedToken) {
      console.log("[Meta Webhook GET] Verification SUCCESS! Returning challenge.");
      return new Response(challenge ?? "ok", {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "text/plain; charset=utf-8",
        },
      });
    }

    // 2b. OAuth Redirect fallback (if user configured webhook URL as OAuth redirect URL)
    const code = url.searchParams.get("code");
    if (code) {
      const authRedirect = new URL("https://rwkebciwvsmavsigdrfa.supabase.co/functions/v1/instagram-auth");
      authRedirect.search = url.search;
      return Response.redirect(authRedirect.toString(), 302);
    }

    // Direct browser hit for health/status diagnostic check
    if (!mode && !token) {
      return new Response(
        JSON.stringify({
          status: "active",
          service: "Allora Instagram Webhook Gateway",
          expected_verify_token: DEFAULT_VERIFY_TOKEN,
          timestamp: new Date().toISOString(),
          instructions: "Use this URL in Meta Developer Dashboard as the Webhook Callback URL.",
        }),
        {
          status: 200,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json",
          },
        }
      );
    }

    console.warn(`[Meta Webhook GET] Verification FAILED: token mismatch. Received: ${token}`);
    return new Response("Forbidden: Verify token mismatch", {
      status: 403,
      headers: corsHeaders,
    });
  }

  // ─── 3. POST REQUEST: EVENT NOTIFICATIONS & OUTBOUND SENDING ────────────
  if (req.method === "POST") {
    try {
      const body = await req.json();

      // Sub-route: Outbound DM sending via Instagram Graph API
      if (url.pathname.endsWith("/send") || body.action === "send_message") {
        const { recipient_id, text, access_token } = body;
        if (!recipient_id || !text || !access_token) {
          return new Response(
            JSON.stringify({ error: "Missing recipient_id, text, or access_token" }),
            { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }

        const graphUrl = `https://graph.instagram.com/v21.0/me/messages`;
        const sendRes = await fetch(graphUrl, {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${access_token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            recipient: { id: recipient_id },
            message: { text },
          }),
        });

        const sendData = await sendRes.json();
        return new Response(JSON.stringify(sendData), {
          status: sendRes.status,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Meta Webhook Delivery Payload: { object: "instagram" | "page", entry: [...] }
      console.log("[Meta Webhook POST] Payload received:", JSON.stringify(body));

      let processedCount = 0;

      if (body.object === "instagram" || body.object === "page") {
        const entries = body.entry || [];
        for (const entry of entries) {
          const accountId = entry.id; // Page or IG business ID
          const messagingEvents = entry.messaging || [];

          for (const event of messagingEvents) {
            const senderId = event.sender?.id;
            const recipientId = event.recipient?.id;
            const timestamp = event.timestamp ? new Date(event.timestamp).toISOString() : new Date().toISOString();
            const message = event.message;
            const reaction = event.reaction;
            const isEcho = message?.is_echo === true;
            const participantId = isEcho ? recipientId : senderId;

            if (!participantId || !accountId) continue;

            const mid = message?.mid || reaction?.mid || `msg_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
            const messageText = message?.text || (reaction ? `Reacted ${reaction.emoji || reaction.reaction}` : "") || (message?.attachments?.length ? "[Media attachment]" : "");

            const conversationId = `conv_${accountId}_${participantId}`;

            // 1. Ensure the Instagram account record exists (so FK constraints pass)
            await supabase.from("instagram_accounts").upsert({
              id: accountId,
              updated_at: new Date().toISOString(),
            }, { onConflict: "id" });

            // 2. Upsert conversation thread
            await supabase.from("instagram_conversations").upsert({
              id: conversationId,
              account_id: accountId,
              participant_id: participantId,
              last_message: messageText,
              last_message_time: timestamp,
              unread_count: isEcho ? 0 : 1,
              updated_at: new Date().toISOString(),
            });

            // Insert message
            await supabase.from("instagram_messages").upsert({
              id: mid,
              conversation_id: conversationId,
              account_id: accountId,
              sender_id: senderId,
              recipient_id: recipientId,
              text: messageText,
              attachments: message?.attachments || [],
              is_echo: isEcho,
              raw_payload: event,
              created_at: timestamp,
            });

            processedCount++;
          }
        }
      }

      // Always return 200 OK to Meta immediately so webhook subscriptions remain active
      return new Response(JSON.stringify({ ok: true, processed: processedCount }), {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      });
    } catch (err: any) {
      console.error("[Meta Webhook POST] Error processing webhook event:", err);
      // Still return 200 to prevent Meta from retrying indefinitely on bad payload
      return new Response(JSON.stringify({ ok: false, error: err.message }), {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      });
    }
  }

  return new Response("Method not allowed", { status: 405, headers: corsHeaders });
});
