document.addEventListener('DOMContentLoaded', async () => {
  const intGrid = document.getElementById('integrations-grid');
  if (intGrid) {
    let items = [];
    try {
      const res = await fetch('/data/integrations.json');
      items = await res.json();
    } catch {
      intGrid.textContent = 'Unable to load connector catalog.';
      return;
    }

    const render = (cat) => {
      const filtered = cat === 'all' ? items : items.filter((x) => x.category === cat);
      intGrid.innerHTML = filtered.map((item) => `
        <article class="card">
          <div class="k">${item.category} &bull; ${item.latency}</div>
          <h3 style="margin:.45rem 0">${item.name}</h3>
          <p class="muted" style="margin:0">${item.description}</p>
        </article>
      `).join('');
    };

    render('all');
    document.querySelectorAll('[data-cat]').forEach((btn) => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('[data-cat]').forEach((b) => b.classList.remove('active'));
        btn.classList.add('active');
        render(btn.getAttribute('data-cat'));
      });
    });
  }

  const demoForm = document.getElementById('demo-request-form');
  if (demoForm) {
    demoForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      const status = document.getElementById('demo-status');
      status.textContent = 'Submitting workspace request...';
      try {
        const res = await fetch('/api/v1/demo-request', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            email: document.getElementById('work-email').value.trim(),
            company: document.getElementById('company-name').value.trim(),
            volume: document.getElementById('event-volume').value
          })
        });
        const data = await res.json().catch(() => ({}));
        status.textContent = data.message || 'Workspace request queued.';
      } catch {
        status.textContent = 'Unable to reach request endpoint.';
      }
    });
  }
});
