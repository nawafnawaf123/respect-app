import "@supabase/functions-js/edge-runtime.d.ts";

Deno.serve(async (req) => {
  const body = await req.json().catch(() => ({}));
  const name = typeof body.name === "string" && body.name.trim().length > 0
    ? body.name.trim()
    : "Respect";

  return new Response(
    JSON.stringify({ message: `Hello ${name}!` }),
    { headers: { "Content-Type": "application/json" } },
  );
});
