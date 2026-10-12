(() => {
  'use strict';
  document.querySelectorAll('[data-provider-setup]').forEach(form => {
    const authentication = form.querySelector('[data-provider-authentication]');
    if (!authentication) return;
    const update = () => {
      const password = authentication.value === 'password';
      form.querySelectorAll('[data-provider-credential]').forEach(input => {
        input.disabled = !password;
        const label = input.closest('label'); if (label) label.hidden = !password;
      });
      form.querySelectorAll('[data-provider-registration]').forEach(field => {
        field.hidden = !password;
        field.querySelectorAll('input').forEach(input => { input.disabled = !password; });
      });
    };
    authentication.addEventListener('change', update); update();
  });
  const board = document.querySelector('[data-core-board]');
  if (!board) return;
  const status = board.querySelector('.core-live-status');
  const callsNode = board.querySelector('.core-live-calls');
  const peopleNode = board.querySelector('.core-live-people');
  const queuesNode = board.querySelector('.core-live-queues');
  const search = board.querySelector('.core-people-search');
  let token = null, people = [], busy = false, stopped = false;
  const text = (tag, value, className) => { const node = document.createElement(tag); node.textContent = String(value); if (className) node.className = className; return node; };
  const button = (label, callback, danger = false) => { const node = text('button', label, 'setup-button' + (danger ? ' danger' : '')); node.type = 'button'; node.addEventListener('click', callback); return node; };
  const selectPeople = () => { const node = document.createElement('select'); node.setAttribute('aria-label', 'Choose a user'); node.append(new Option('Choose a user', '')); people.forEach(p => node.append(new Option(`${p.name} · ${p.number}`, p.number))); return node; };
  async function request(body) {
    const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch('/app/pbx_setup/live.php', { method: body ? 'POST' : 'GET', credentials: 'same-origin', cache: 'no-store', signal: controller.signal, ...(body ? { body } : {}) });
      const data = await response.json(); if (data.token) token = data.token;
      if (!response.ok || data.error) throw new Error(data.error || 'The call list is temporarily unavailable.');
      return data;
    } finally { clearTimeout(timer); }
  }
  async function act(id, operation, target = '', extra = {}) {
    if (busy || !token) return;
    busy = true; status.textContent = 'Updating call…';
    const body = new URLSearchParams({ call: id, operation, target, ...extra }); body.set(token.name, token.hash);
    try { const result = await request(body); status.textContent = result.message; }
    catch (error) { status.textContent = error.message; }
    finally { busy = false; void refresh(); }
  }
  function renderPeople() {
    peopleNode.replaceChildren(); const query = search.value.trim().toLocaleLowerCase();
    people.filter(p => `${p.name} ${p.number}`.toLocaleLowerCase().includes(query)).forEach(p => { const card = text('div', '', 'core-person'); card.append(text('strong', `${p.name} · ${p.number}`), text('span', p.status)); peopleNode.append(card); });
    if (!peopleNode.childElementCount) peopleNode.append(text('p', 'No matching people.'));
  }
  function render(data) {
    people = data.people || []; const switchboard = board.dataset.coreBoard === 'switchboard';
    if (document.activeElement?.matches('.core-call select')) { status.textContent = 'Live · choose your call action'; return; }
    const selected = new Map([...callsNode.querySelectorAll('[data-call-id]')].map(node => [node.dataset.callId, [...node.querySelectorAll('select')].map(s => s.value)]));
    callsNode.replaceChildren(); queuesNode.replaceChildren(); peopleNode.hidden = !switchboard; search.hidden = !switchboard;
    if (switchboard) {
      renderPeople(); callsNode.append(text('h3', 'Live Calls'));
      (data.calls || []).forEach(call => {
        const state = { ACTIVE: 'Connected', RINGING: 'Ringing', EARLY: 'Connecting', HELD: 'On Hold', CS_EXECUTE: 'In a Call', CS_ROUTING: 'Connecting', HANGUP: 'Ending' }[call.state] || 'In Progress';
        const card = text('div', '', 'core-call'); card.dataset.callId = call.id; card.append(text('strong', `${call.from || call.name || 'Caller'} → ${call.to || call.user || 'PBX'}`), text('p', call.parked ? 'Parked' : state));
        if (data.can_control) {
          const actions = text('div', '', 'setup-actions'); actions.append(button('Hold', () => act(call.id, 'hold')), button('Resume', () => act(call.id, 'resume')));
          const who = selectPeople(); who.value = selected.get(call.id)?.[0] || ''; actions.append(who, button('Transfer', () => { if (who.value) void act(call.id, 'transfer', who.value); else status.textContent = 'Choose a user first.'; }), button('Pick Up', () => { if (who.value) void act(call.id, 'pickup', who.value); else status.textContent = 'Choose the phone you want to answer on.'; }));
          if (data.parking_enabled) { const space = document.createElement('select'); space.setAttribute('aria-label', 'Parking space'); for (let n = 1; n <= 20; n++) space.append(new Option(`Parking ${n}`, String(n))); space.value = selected.get(call.id)?.[1] || '1'; actions.append(space, button('Park', () => act(call.id, 'park', space.value))); }
          actions.append(button('End', () => { if (window.confirm('End this call?')) void act(call.id, 'end'); }, true)); card.append(actions);
        }
        callsNode.append(card);
      });
      if (!data.calls?.length) callsNode.append(text('p', 'No active calls.'));
    } else {
      (data.queues || []).forEach(queue => {
        const card = text('div', '', 'core-queue' + (queue.alert ? ' core-queue-alert' : '')); card.append(text('h3', `${queue.name} · ${queue.number}`), text('p', `${queue.waiting} waiting · longest wait ${Math.max(0, queue.longest_wait)} seconds`));
        if (queue.alert) card.append(text('strong', 'Waiting longer than your service target.'));
        queue.agents.forEach(agent => {
          const state = { Available: 'Ready', 'Available (On Demand)': 'Ready', 'On Break': 'On a Break', 'Logged Out': 'Signed Out' }[agent.status] || 'Unavailable';
          const row = text('div', '', 'core-agent'); row.append(text('p', `${agent.name} · ${agent.joined ? state : 'Signed Out'} · ${agent.state === 'Waiting' ? 'Waiting for a Call' : (agent.state === 'In a queue call' ? 'In a Call' : 'Busy')}`));
          if (data.can_supervise) row.append(button('Ready', () => act('', 'agent', '', { queue: queue.number, number: agent.number, agent_state: 'ready' })), button('Break', () => act('', 'agent', '', { queue: queue.number, number: agent.number, agent_state: 'break' })), button('Sign Out', () => act('', 'agent', '', { queue: queue.number, number: agent.number, agent_state: 'logout' })));
          card.append(row);
        });
        queuesNode.append(card);
      });
      if (!data.queues?.length) queuesNode.append(text('p', 'No call queues configured.'));
    }
    status.textContent = 'Live · updated ' + new Date(data.server_time).toLocaleTimeString();
  }
  async function refresh() {
    if (busy || stopped || document.hidden) return;
    busy = true;
    try { render(await request()); }
    catch (error) { status.textContent = error.name === 'AbortError' ? 'Connection is taking longer than usual. Retrying…' : error.message + ' Retrying…'; }
    finally { busy = false; }
  }
  search.addEventListener('input', renderPeople);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) void refresh(); });
  const timer = setInterval(() => void refresh(), 3000);
  window.addEventListener('pagehide', () => { stopped = true; clearInterval(timer); });
  void refresh();
})();
