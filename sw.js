self.addEventListener("push", event => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (error) {
    console.error("Invalid push notification payload:", error);
  }

  const title = typeof payload.title === "string" ? payload.title.slice(0, 80) : "Чаты";
  const options = {
    body: typeof payload.body === "string" ? payload.body.slice(0, 180) : "У вас новое уведомление.",
    tag: typeof payload.tag === "string" ? payload.tag.slice(0, 100) : "chat-notification",
    renotify: false,
    data: {
      conversationId: typeof payload.conversationId === "string" ? payload.conversationId : "",
      callId: typeof payload.callId === "string" ? payload.callId : ""
    }
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const data = event.notification.data || {};
  const url = new URL("./index.html", self.location.href);
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(data.conversationId || "")) {
    url.searchParams.set("conversation", data.conversationId);
  }
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(data.callId || "")) {
    url.searchParams.set("incomingCall", data.callId);
  }

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of windows) {
      if (client.url.startsWith(self.location.origin) && "focus" in client) {
        await client.navigate(url.href);
        return client.focus();
      }
    }
    return self.clients.openWindow(url.href);
  })());
});
