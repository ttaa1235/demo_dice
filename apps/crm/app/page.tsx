const cards = [
  ["유저", "players"],
  ["배팅", "bets"],
  ["입금", "deposit_requests"],
  ["출금", "withdrawal_requests"],
  ["원장", "ledger_transactions"]
];

export default function Home() {
  return (
    <main className="shell">
      <section className="hero">
        <p className="eyebrow">Demo Dice CRM</p>
        <h1>운영 대시보드</h1>
        <p>Supabase RPC 기반 주사위 배팅 봇의 운영 상태를 확인하는 관리자 콘솔입니다.</p>
      </section>
      <section className="grid">
        {cards.map(([label, table]) => (
          <a className="card" key={table} href={`/admin/${table}`}>
            <span>{label}</span>
            <strong>{table}</strong>
          </a>
        ))}
      </section>
    </main>
  );
}