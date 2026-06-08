// supabase/functions/send-notification/index.ts
import { serve } from "https://deno.land/[email protected]/http/server.ts";
import { GoogleAuth } from "https://esm.sh/google-auth-library";

// قراءة بيانات حساب الخدمة من متغير البيئة
const serviceAccountJson = Deno.env.get("SERVICE_ACCOUNT_JSON");
if (!serviceAccountJson) throw new Error("Missing SERVICE_ACCOUNT_JSON");

const credentials = JSON.parse(serviceAccountJson);

serve(async (req) => {
  try {
    // 1. استلام البيانات من تطبيق Flutter
    const { token, title, body, data, type } = await req.json();

    if (!token || !title) {
      return new Response(JSON.stringify({ error: "Missing token or title" }), { status: 400 });
    }

    // 2. الحصول على Access Token باستخدام Service Account
    const auth = new GoogleAuth({
      credentials: credentials,
      scopes: ["https://www.googleapis.com/auth/firebase.messaging"],
    });
    const client = await auth.getClient();
    const accessToken = await client.getAccessToken();

    // 3. بناء payload الإشعار وفقًا لـ FCM v1
    const fcmPayload = {
      message: {
        token: token,
        notification: {
          title: title,
          body: body,
        },
        android: {
          priority: "high",
          notification: {
            channel_id: type === "call" ? "respect_calls_channel" : "respect_messages_channel",
          },
        },
        apns: {
          payload: {
            aps: {
              sound: "default",
              category: type === "call" ? "INCOMING_CALL" : "NEW_MESSAGE",
            },
          },
        },
        data: data || {},
      },
    };

    // 4. إرسال الإشعار إلى FCM
    const projectId = credentials.project_id;
    const fcmResponse = await fetch(
      `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
      {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(fcmPayload),
      }
    );

    const responseText = await fcmResponse.text();
    if (!fcmResponse.ok) {
      console.error("FCM error:", responseText);
      throw new Error(responseText);
    }

    return new Response(JSON.stringify({ success: true, response: JSON.parse(responseText) }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("Edge Function error:", error.message);
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }
});