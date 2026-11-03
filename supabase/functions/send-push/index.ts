import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("SUPABASE_PUBLISHABLE_KEY")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY")!;
const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY")!;
const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:admin@example.com";
const allowedOrigin = Deno.env.get("PUSH_ALLOWED_ORIGIN") || "*";
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin"
};

function respond(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" }
  });
}

Deno.serve(async request => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return respond(405, { error: "Method not allowed" });

  if (!supabaseUrl || !anonKey || !serviceRoleKey || !vapidPublicKey || !vapidPrivateKey) {
    console.error("Missing Supabase or VAPID environment configuration.");
    return respond(503, { error: "Push notifications are not configured." });
  }

  try {
    const authorization = request.headers.get("Authorization");
    const token = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
    if (!token) return respond(401, { error: "Authentication required." });

    const body = await request.json().catch(() => null);
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return respond(400, { error: "Invalid notification request." });
    }
    const action = (body as { action?: unknown }).action;
    const id = (body as { id?: unknown }).id;
    if (typeof action !== "string" || !["message", "call"].includes(action) ||
        typeof id !== "string" || !uuidPattern.test(id)) {
      return respond(400, { error: "Invalid notification request." });
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } }
    });
    const { data: { user }, error: authError } = await userClient.auth.getUser(token);
    if (authError || !user) return respond(401, { error: "Invalid authentication." });

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });

    let targetIds: string[] = [];
    let notification: Record<string, unknown>;

    if (action === "message") {
      const { data: message, error: messageError } = await admin.from("messages")
        .select("id, author_id, conversation_id, body, attachment")
        .eq("id", id).maybeSingle();
      if (messageError) throw messageError;
      if (!message || message.author_id !== user.id) return respond(404, { error: "Message not found." });

      const [{ data: conversation, error: conversationError }, { data: members, error: membersError }, { data: author, error: authorError }] = await Promise.all([
        admin.from("conversations").select("id, kind, title").eq("id", message.conversation_id).maybeSingle(),
        admin.from("conversation_members").select("user_id").eq("conversation_id", message.conversation_id),
        admin.from("profiles").select("display_name").eq("id", user.id).maybeSingle()
      ]);
      if (conversationError) throw conversationError;
      if (membersError) throw membersError;
      if (authorError) throw authorError;
      const memberIds = (members || []).map((member: { user_id: string }) => member.user_id);
      if (!conversation || !memberIds.includes(user.id)) return respond(403, { error: "Not a conversation member." });
      targetIds = memberIds.filter((memberId: string) => memberId !== user.id);
      notification = {
        title: conversation.kind === "group" ? conversation.title : author?.display_name || "Новое сообщение",
        body: message.attachment ? "Вам отправили файл" : String(message.body || "").slice(0, 160),
        tag: `message-${message.id}`,
        conversationId: message.conversation_id
      };
    } else {
      const { data: signal, error: signalError } = await admin.from("call_signals")
        .select("id, call_id, sender_id, recipient_id, kind, payload, created_at")
        .eq("id", id).gte("created_at", new Date(Date.now() - 60000).toISOString()).maybeSingle();
      if (signalError) throw signalError;
      if (!signal || signal.sender_id !== user.id || signal.kind !== "offer") {
        return respond(404, { error: "Call offer not found." });
      }

      const [{ data: history, error: historyError }, { data: recipient, error: recipientError }, { data: caller, error: callerError }] = await Promise.all([
        admin.from("call_history").select("call_id").eq("call_id", signal.call_id).eq("status", "ringing").maybeSingle(),
        admin.from("profiles").select("id").eq("id", signal.recipient_id).maybeSingle(),
        admin.from("profiles").select("display_name").eq("id", user.id).maybeSingle()
      ]);
      if (historyError) throw historyError;
      if (recipientError) throw recipientError;
      if (callerError) throw callerError;
      if (!history || !recipient) return respond(404, { error: "Active call not found." });
      targetIds = [signal.recipient_id];
      notification = {
        title: caller?.display_name || "Входящий звонок",
        body: signal.payload?.callKind === "video" ? "Входящий видеозвонок" : "Входящий аудиозвонок",
        tag: `call-${signal.call_id}`,
        callId: signal.call_id
      };
    }

    if (!targetIds.length) return respond(200, { sent: 0 });

    const { data: subscriptions, error: subscriptionsError } = await admin.from("push_subscriptions")
      .select("user_id, endpoint, p256dh, auth")
      .in("user_id", targetIds);
    if (subscriptionsError) throw subscriptionsError;
    if (!subscriptions?.length) return respond(200, { sent: 0 });

    webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);
    const payload = JSON.stringify(notification);
    const results = await Promise.allSettled(subscriptions.map(async (subscription: {
      endpoint: string; p256dh: string; auth: string;
    }) => {
      try {
        await webpush.sendNotification({
          endpoint: subscription.endpoint,
          keys: { p256dh: subscription.p256dh, auth: subscription.auth }
        }, payload, { TTL: 60, urgency: action === "call" ? "high" : "normal" });
        return true;
      } catch (error) {
        const statusCode = (error as { statusCode?: number }).statusCode;
        if (statusCode === 404 || statusCode === 410) {
          const { error: deleteError } = await admin.from("push_subscriptions")
            .delete().eq("endpoint", subscription.endpoint);
          if (deleteError) console.error("Could not remove expired push subscription:", deleteError);
          return false;
        }
        throw error;
      }
    }));

    let sent = 0;
    for (const result of results) {
      if (result.status === "fulfilled" && result.value) sent += 1;
      else if (result.status === "rejected") console.error("Push delivery failed:", result.reason);
    }
    return respond(200, { sent });
  } catch (error) {
    console.error("Push notification request failed:", error);
    return respond(500, { error: "Could not send push notifications." });
  }
});
