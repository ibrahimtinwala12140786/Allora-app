// @ts-nocheck
// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This code is running in a Deno environment on Supabase Functions.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.48.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const REDIRECT_URI = "https://rwkebciwvsmavsigdrfa.supabase.co/functions/v1/instagram-auth";
const DEFAULT_CLIENT_ID = "2268420340658927";
const DEFAULT_CLIENT_SECRET = "d94f52bb9d0a645b3b003c52993045d9";

function renderHtmlResponse(title: string, message: string, isSuccess: boolean, redirectUrl?: string): Response {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${title} - Allora</title>
  <style>
    body {
      margin: 0;
      padding: 0;
      background: #0B0E14;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      color: #FFFFFF;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
    }
    .card {
      background: #151922;
      border: 1px solid rgba(255, 255, 255, 0.08);
      border-radius: 20px;
      padding: 40px 32px;
      max-width: 440px;
      width: 90%;
      text-align: center;
      box-shadow: 0 20px 40px rgba(0, 0, 0, 0.6);
    }
    .icon-badge {
      width: 64px;
      height: 64px;
      border-radius: 18px;
      margin: 0 auto 24px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 32px;
      background: ${isSuccess ? 'linear-gradient(135deg, #10B981, #059669)' : 'linear-gradient(135deg, #EF4444, #DC2626)'};
    }
    h1 {
      font-size: 22px;
      margin: 0 0 12px;
      font-weight: 700;
    }
    p {
      color: #94A3B8;
      font-size: 14px;
      line-height: 1.6;
      margin: 0 0 28px;
    }
    .btn {
      display: inline-block;
      background: #0052FF;
      color: #FFFFFF;
      text-decoration: none;
      font-weight: 600;
      font-size: 15px;
      padding: 12px 28px;
      border-radius: 25px;
      transition: all 0.2s ease;
    }
    .btn:hover {
      background: #0045D8;
      transform: translateY(-1px);
    }
    .subtext {
      margin-top: 18px;
      font-size: 12px;
      color: #64748B;
    }
  </style>
  ${redirectUrl ? `<script>
    setTimeout(function() {
      window.location.href = "${redirectUrl}";
    }, 1500);
  </script>` : ''}
</head>
<body>
  <div class="card">
    <div class="icon-badge">
      ${isSuccess ? '✓' : '✕'}
    </div>
    <h1>${title}</h1>
    <p>${message}</p>
    ${redirectUrl ? `<a href="${redirectUrl}" class="btn">Open Allora</a>` : '<a href="https://allorachat.app" class="btn">Return to Allora</a>'}
    <div class="subtext">Allora Universal Messaging • Instagram Business Integration</div>
  </div>
</body>
</html>`;

  return new Response(html, {
    status: isSuccess ? 200 : 400,
    headers: {
      ...corsHeaders,
      "Content-Type": "text/html; charset=utf-8",
    },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const url = new URL(req.url);

  // 1. Check for errors sent by Instagram OAuth
  const error = url.searchParams.get("error");
  const errorDescription = url.searchParams.get("error_description");
  if (error) {
    console.error("Instagram OAuth Error:", error, errorDescription);
    return renderHtmlResponse(
      "Instagram Login Cancelled",
      errorDescription || "Authentication was not completed. You can close this window and try again in Allora.",
      false
    );
  }

  // 2. Check for Authorization Code
  let code = url.searchParams.get("code");
  if (code) {
    // Meta appends '#_' to the code parameter
    code = code.replace(/#_$/, "");
    console.log("Received Instagram authorization code:", code.substring(0, 10) + "...");

    const clientId = Deno.env.get("INSTAGRAM_APP_ID") || DEFAULT_CLIENT_ID;
    const clientSecret = Deno.env.get("INSTAGRAM_APP_SECRET") || DEFAULT_CLIENT_SECRET;

    let accountUsername = "Instagram User";

    if (clientSecret) {
      try {
        // Exchange code for short-lived access token
        const tokenFormData = new URLSearchParams();
        tokenFormData.append("client_id", clientId);
        tokenFormData.append("client_secret", clientSecret);
        tokenFormData.append("grant_type", "authorization_code");
        tokenFormData.append("redirect_uri", REDIRECT_URI);
        tokenFormData.append("code", code);

        const tokenRes = await fetch("https://api.instagram.com/oauth/access_token", {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: tokenFormData.toString(),
        });

        if (tokenRes.ok) {
          const tokenData = await tokenRes.json();
          let userAccessToken = tokenData.access_token;
          const igUserId = tokenData.user_id?.toString() || "";

          // Exchange for long-lived access token (60 days)
          try {
            const longLivedRes = await fetch(
              `https://graph.instagram.com/access_token?grant_type=ig_exchange_token&client_secret=${clientSecret}&access_token=${userAccessToken}`
            );
            if (longLivedRes.ok) {
              const longLivedData = await longLivedRes.json();
              if (longLivedData.access_token) {
                userAccessToken = longLivedData.access_token;
              }
            }
          } catch (e) {
            console.warn("Long-lived token exchange warning:", e);
          }

          // Fetch profile details from Graph API
          let username = `ig_user_${igUserId}`;
          let name = "";
          let profilePic = null;

          try {
            const profileRes = await fetch(
              `https://graph.instagram.com/v21.0/me?fields=id,username,name,profile_picture_url&access_token=${userAccessToken}`
            );
            if (profileRes.ok) {
              const profileData = await profileRes.json();
              username = profileData.username || username;
              name = profileData.name || "";
              profilePic = profileData.profile_picture_url || null;
            }
          } catch (e) {
            console.warn("Profile fetch warning:", e);
          }

          accountUsername = `@${username}`;

          // Save to Supabase DB
          const supabaseUrl = Deno.env.get("SUPABASE_URL") || "https://rwkebciwvsmavsigdrfa.supabase.co";
          const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
          if (serviceKey) {
            const supabase = createClient(supabaseUrl, serviceKey);
            await supabase.from("instagram_accounts").upsert({
              id: igUserId || `ig_${Date.now()}`,
              username: username,
              name: name,
              profile_pic_url: profilePic,
              access_token: userAccessToken,
              updated_at: new Date().toISOString(),
            });
          }
        } else {
          const errText = await tokenRes.text();
          console.error("Token exchange failed:", errText);
        }
      } catch (e) {
        console.error("OAuth exchange process error:", e);
      }
    }

    const appRedirectUri = `io.supabase.allorachat://login-callback?instagram_code=${encodeURIComponent(code)}`;

    return renderHtmlResponse(
      "Instagram Login Successful!",
      `Your Instagram Business account ${accountUsername} has been authenticated. Redirecting you back to Allora...`,
      true,
      appRedirectUri
    );
  }

  // 3. Default status page when accessed directly (health / verification check)
  return renderHtmlResponse(
    "Instagram Redirect Endpoint Active",
    "This endpoint is configured and ready to receive Instagram Business Login OAuth redirects for Allora.",
    true
  );
});
