document.addEventListener('DOMContentLoaded', async () => {
  const archiveHost = document.getElementById('posts-archive');
  if (archiveHost) {
    try {
      const res = await fetch('/data/posts.json');
      const posts = await res.json();
      const searchInput = document.getElementById('topic-search');
      const render = (q) => {
        const needle = (q || '').trim().toLowerCase();
        const list = needle
          ? posts.filter((p) => (p.title + ' ' + p.summary + ' ' + p.topic).toLowerCase().includes(needle))
          : posts;
        archiveHost.innerHTML = list.map((p) => `
          <article class="card">
            <div class="meta">${p.date} &bull; <span class="tag-chip">${p.topic}</span> &bull; ${p.read_time}</div>
            <h2><a href="${p.url}">${p.title}</a></h2>
            <p class="muted">${p.summary}</p>
            <a href="${p.url}">Read article &rarr;</a>
          </article>
        `).join('') || '<p class="muted">No matching articles found.</p>';
      };
      render('');
      if (searchInput) {
        searchInput.addEventListener('input', () => render(searchInput.value));
      }
    } catch {
      archiveHost.textContent = 'Unable to load article archive.';
    }
  }

  const form = document.getElementById('newsletter-form');
  if (form) {
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const msg = document.getElementById('newsletter-msg');
      const email = document.getElementById('digest-email').value.trim();
      msg.textContent = 'Subscribing...';
      try {
        const res = await fetch('/api/v1/newsletter', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email })
        });
        const data = await res.json().catch(() => ({}));
        msg.textContent = data.message || 'Subscription queued.';
      } catch {
        msg.textContent = 'Subscription service temporarily unavailable.';
      }
    });
  }
});
