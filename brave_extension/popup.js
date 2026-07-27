document.addEventListener('DOMContentLoaded', () => {
    const input = document.getElementById('chat-input');
    const history = document.getElementById('chat-history');
    const sendBtn = document.getElementById('send-btn');

    async function sendMessage() {
        const text = input.value.trim();
        if (!text) return;

        // Append User Message
        history.innerHTML += `<div class="user-msg">[USER] ${text}</div>`;
        input.value = '';
        history.scrollTop = history.scrollHeight;

        // Get context from active tab
        let pageContext = "";
        try {
            const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
            const injection = await chrome.scripting.executeScript({
                target: { tabId: tab.id },
                func: () => document.body.innerText.substring(0, 1500) // Grab first 1500 chars for context
            });
            if (injection && injection[0] && injection[0].result) {
                pageContext = injection[0].result;
            }
        } catch (e) {
            console.log("Could not extract page context:", e);
        }

        const fullQuery = pageContext ? `Context from current webpage:\n${pageContext}\n\nUser Question:\n${text}` : text;

        try {
            history.innerHTML += `<div class="sys-msg" id="loading">[SYS] Transmitting to Colibri...</div>`;
            history.scrollTop = history.scrollHeight;

            const response = await fetch('http://127.0.0.1:8081/api/chat', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ message: fullQuery })
            });

            document.getElementById('loading').remove();
            
            if (response.ok) {
                const data = await response.json();
                const cleanAns = data.response.replace(/\n/g, '<br>');
                history.innerHTML += `<div class="sys-msg">[GODBRAIN]<br>${cleanAns}</div>`;
            } else {
                history.innerHTML += `<div class="err-msg">[ERR] API returned ${response.status}</div>`;
            }
        } catch (err) {
            const loadingEl = document.getElementById('loading');
            if(loadingEl) loadingEl.remove();
            history.innerHTML += `<div class="err-msg">[ERR] Node Offline. Is api_server.py running?</div>`;
        }
        history.scrollTop = history.scrollHeight;
    }

    sendBtn.addEventListener('click', sendMessage);
    input.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') sendMessage();
    });
});
