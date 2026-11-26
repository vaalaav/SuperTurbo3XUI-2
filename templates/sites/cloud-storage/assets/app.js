document.addEventListener('DOMContentLoaded', () => {
  const form = document.getElementById('console-auth-form');
  if (form) {
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const msg = document.getElementById('auth-msg');
      const keyInput = document.getElementById('access-key');
      const secretInput = document.getElementById('secret-key');
      msg.textContent = 'Verifying S3 access key...';
      try {
        const res = await fetch('/api/v1/auth/session', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            accessKeyId: keyInput ? keyInput.value.trim() : '',
            secretLen: secretInput ? secretInput.value.length : 0
          })
        });
        if (res.status === 429) {
          msg.textContent = 'Too many authentication attempts. Please wait a minute.';
          return;
        }
        const data = await res.json().catch(() => ({}));
        msg.textContent = data.message || 'Invalid access key or expired session token.';
      } catch {
        msg.textContent = 'Authentication gateway temporarily unreachable.';
      }
    });
  }

  const pingBtn = document.getElementById('check-gateway-btn');
  if (pingBtn) {
    pingBtn.addEventListener('click', async () => {
      const out = document.getElementById('gateway-probe-out');
      out.textContent = 'Checking gateway...';
      try {
        const res = await fetch('/api/v1/status');
        const data = await res.json();
        out.textContent = JSON.stringify(data, null, 2);
      } catch {
        out.textContent = 'Unable to reach /api/v1/status';
      }
    });
  }
});
