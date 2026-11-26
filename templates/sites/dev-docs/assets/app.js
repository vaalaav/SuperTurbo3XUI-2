document.addEventListener('DOMContentLoaded', () => {
  const tryBtn = document.getElementById('try-status-btn');
  if (tryBtn) {
    tryBtn.addEventListener('click', async () => {
      const box = document.getElementById('try-status-out');
      box.textContent = 'Requesting GET /api/v1/status ...';
      try {
        const res = await fetch('/api/v1/status');
        const body = await res.json();
        box.textContent = `HTTP ${res.status}\n` + JSON.stringify(body, null, 2);
      } catch {
        box.textContent = 'Request failed.';
      }
    });
  }

  const tokenForm = document.getElementById('token-test-form');
  if (tokenForm) {
    tokenForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      const box = document.getElementById('token-test-out');
      box.textContent = 'POST /api/v1/auth/token ...';
      try {
        const res = await fetch('/api/v1/auth/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            client_id: document.getElementById('client-id').value.trim(),
            grant_type: 'client_credentials'
          })
        });
        const body = await res.json().catch(() => ({}));
        box.textContent = `HTTP ${res.status}\n` + JSON.stringify(body, null, 2);
      } catch {
        box.textContent = 'Token exchange failed.';
      }
    });
  }
});
