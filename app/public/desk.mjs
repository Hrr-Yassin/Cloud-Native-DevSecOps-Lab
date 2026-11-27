const find = (id) => document.getElementById(id);
const label = { open: 'Open', in_progress: 'In progress', resolved: 'Resolved' };
const login = find('login-form');
const add = find('add-form');
let session;
let next;

function message(text) {
  find('notice').textContent = text;
}

function view() {
  find('login').hidden = Boolean(session);
  find('workspace').hidden = !session;
  find('sign-out').hidden = !session;
  find('account').textContent = session?.username ?? '';
  add.hidden = session?.role !== 'admin';
  if (!session) {
    find('findings').replaceChildren();
    find('empty').hidden = false;
    find('load-more').hidden = true;
    next = null;
  }
}

async function request(path, method = 'GET', body) {
  const headers = {};
  if (body) headers['content-type'] = 'application/json';
  if (session?.csrf) headers['x-csrf-token'] = session.csrf;
  const response = await fetch(path, {
    method, headers, body: body ? JSON.stringify(body) : undefined,
  });
  if (response.status === 401) {
    const expired = Boolean(session);
    session = null;
    view();
    if (expired) throw new Error('Your session ended. Sign in again.');
    throw new Error('Check your username and password.');
  }
  if (response.status === 429) throw new Error('Too many attempts. Try again in a few minutes.');
  if (!response.ok) throw new Error('The request could not be completed.');
  return response.status === 204 ? null : response.json();
}

function row(finding) {
  const tr = document.createElement('tr');
  const title = tr.insertCell();
  title.textContent = finding.title;
  const severity = document.createElement('span');
  severity.className = `severity ${finding.severity}`;
  severity.textContent = finding.severity;
  tr.insertCell().append(severity);
  const status = tr.insertCell();
  if (session?.role !== 'admin') {
    status.textContent = label[finding.status];
    return tr;
  }
  const select = document.createElement('select');
  select.setAttribute('aria-label', `Status for finding ${finding.id}`);
  for (const [key, text] of Object.entries(label)) select.add(new Option(text, key));
  select.value = finding.status;
  select.addEventListener('change', async () => {
    select.disabled = true;
    try {
      const updated = await request(`/api/findings/${finding.id}`, 'PATCH', { status: select.value });
      finding.status = updated.status;
      message('Status updated.');
    } catch (error) {
      select.value = finding.status;
      message(error.message);
    } finally {
      select.disabled = false;
    }
  });
  status.append(select);
  return tr;
}

async function load(append = false) {
  const suffix = append && next !== null ? `?after=${next}` : '';
  const result = await request(`/api/findings${suffix}`);
  next = result.next;
  const table = find('findings');
  if (!append) table.replaceChildren();
  table.append(...result.findings.map(row));
  find('empty').hidden = table.childElementCount > 0;
  find('load-more').hidden = next === null;
}

async function busy(button, action) {
  button.disabled = true;
  message('');
  try {
    await action();
  } catch (error) {
    message(error.message);
  } finally {
    button.disabled = false;
  }
}

login.addEventListener('submit', (event) => {
  event.preventDefault();
  const fields = Object.fromEntries(new FormData(login));
  find('password').value = '';
  void busy(event.submitter, async () => {
    session = await request('/api/session', 'POST', fields);
    view();
    await load();
  });
});
add.addEventListener('submit', (event) => {
  event.preventDefault();
  const fields = Object.fromEntries(new FormData(add));
  void busy(event.submitter, async () => {
    await request('/api/findings', 'POST', fields);
    add.reset();
    await load();
    message('Finding added.');
  });
});
find('sign-out').addEventListener('click', (event) => {
  void busy(event.currentTarget, async () => {
    await request('/api/session', 'DELETE');
    session = null;
    view();
  });
});
find('load-more').addEventListener('click', (event) => {
  void busy(event.currentTarget, () => load(true));
});

try {
  session = await request('/api/session');
  view();
  await load();
} catch {
  view();
} finally {
  find('sign-in').disabled = false;
}
