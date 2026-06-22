import { createClient } from "@supabase/supabase-js";

const allowedTables = new Set([
  "players",
  "bets",
  "deposit_requests",
  "withdrawal_requests",
  "ledger_transactions"
]);

async function loadRows(table: string) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key || !allowedTables.has(table)) {
    return [];
  }
  const supabase = createClient(url, key, { auth: { persistSession: false } });
  const { data } = await supabase.from(table).select("*").order("created_at", { ascending: false }).limit(20);
  return data ?? [];
}

export default async function AdminTable({ params }: { params: Promise<{ table: string }> }) {
  const { table } = await params;
  const rows = await loadRows(table);

  return (
    <main className="shell">
      <a href="/">← 대시보드</a>
      <section className="hero">
        <p className="eyebrow">Admin Table</p>
        <h1>{table}</h1>
        <p>최근 20개 레코드입니다.</p>
      </section>
      <pre className="json">{JSON.stringify(rows, null, 2)}</pre>
    </main>
  );
}