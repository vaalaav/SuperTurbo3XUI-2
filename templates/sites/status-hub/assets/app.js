document.addEventListener('DOMContentLoaded', async () => {
  const barsHost = document.querySelectorAll('[data-uptime-bars]');
  barsHost.forEach((el, idx) => {
    const days = 30;
    for (let i = 0; i < days; i++) {
      const b = document.createElement('span');
      b.className = (idx === 1 && i === 18) ? 'bar minor' : 'bar';
      b.title = (idx === 1 && i === 18) ? 'Minor latency spike (resolved)' : '100% Operational';
      el.appendChild(b);
    }
  });

  const incHost = document.getElementById('incidents-feed');
  if (incHost) {
    try {
      const res = await fetch('/data/incidents.json');
      const items = await res.json();
      incHost.innerHTML = items.map((item) => `
        <article class="card" style="margin-bottom:1rem">
          <div style="display:flex;justify-content:space-between;gap:1rem;flex-wrap:wrap">
            <strong>${item.title}</strong>
            <span class="ok">${item.status}</span>
          </div>
          <p class="muted" style="margin:.4rem 0 .2rem">${item.summary}</p>
          <div class="muted" style="font-size:.82rem">${item.date} &bull; Component: ${item.component}</div>
        </article>
      `).join('');
    } catch {
      incHost.textContent = 'Unable to load incident history feed.';
    }
  }

  const subForm = document.getElementById('status-subscribe-form');
  if (subForm) {
    subForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      const msg = document.getElementById('subscribe-msg');
      const email = document.getElementById('sub-email').value.trim();
      msg.textContent = 'Submitting subscription request...';
      try {
        const res = await fetch('/api/v1/subscribe', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email })
        });
        const data = await res.json().catch(() => ({}));
        msg.textContent = data.message || 'Request accepted.';
      } catch {
        msg.textContent = 'Subscription endpoint unreachable.';
      }
    });
  }
});
