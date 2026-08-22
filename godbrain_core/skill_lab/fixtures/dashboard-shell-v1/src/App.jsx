const cards = [
  { id: "mouth", label: "Mouth", value: "llama=serve" },
  { id: "rag", label: "RAG", value: "ready" },
  { id: "inbox", label: "Inbox", value: "0" },
];

export function App() {
  return (
    <div className="shell">
      <aside className="nav" aria-label="Lab navigation">
        <p className="brand">Skill lab</p>
        <a href="#status">Status</a>
      </aside>
      <main id="status">
        <h1>Operations dashboard</h1>
        <p className="hint">Gym fixture. Not Galaxy.</p>
        <section className="cards" aria-label="Live status">
          {cards.map((card) => (
            <article key={card.id} className="card">
              <h2>{card.label}</h2>
              <p>{card.value}</p>
            </article>
          ))}
        </section>
      </main>
    </div>
  );
}
