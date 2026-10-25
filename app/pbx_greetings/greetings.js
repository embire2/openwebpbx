(() => {
    'use strict';
    const create = document.querySelector('[data-create-greeting]');
    if (create) {
        const source = create.querySelector('[data-greeting-source]');
        const refresh = () => {
            const phone = source.value === 'phone';
            create.querySelector('[data-record-phone]').hidden = !phone;
            create.querySelector('[data-record-text]').hidden = phone;
            create.elements.target_number.required = phone;
            create.elements.script.required = !phone;
        };
        source.addEventListener('change', refresh); refresh();
    }
    const filter=document.querySelector('[data-greeting-filter]');
    if(filter)filter.addEventListener('change',()=>document.querySelectorAll('[data-greeting-id]').forEach(item=>item.hidden=filter.value!==''&&item.dataset.greetingCategory!==filter.value));
    document.querySelectorAll('[data-assignment-kind]').forEach(kind=>{
        const refresh=()=>{
            const wanted=['voicemail','extension_hold'].includes(kind.value)?'users':kind.value==='receptionist'?'receptionists':'queues';
            kind.closest('form').querySelectorAll('[data-target-kind]').forEach(option=>{option.hidden=option.dataset.targetKind!==wanted;option.disabled=option.hidden;if(option.hidden)option.selected=false;});
        };
        kind.addEventListener('change',refresh);refresh();
    });
    async function status(){
        try{
            const response=await fetch('/app/pbx_greetings/status.php',{credentials:'same-origin',cache:'no-store',signal:AbortSignal.timeout(8000)});
            if(!response.ok)throw new Error('Status unavailable');
            const payload=await response.json();
            if(payload.readiness){
                const readiness=document.querySelector('[data-greeting-readiness]');if(readiness)readiness.textContent=payload.readiness.message;
                const createButton=document.querySelector('[data-create-greeting-button]');if(createButton)createButton.disabled=!payload.readiness.ready;
            }
            for(const greeting of payload.greetings||[]){
                if(!/^[a-f0-9-]{36}$/.test(greeting.greeting_uuid))continue;
                const item=document.querySelector(`[data-greeting-id="${greeting.greeting_uuid}"]`);if(!item)continue;
                item.querySelector('[data-greeting-state]').textContent=greeting.state.replaceAll('_',' ');
                item.querySelector('[data-greeting-result]').textContent=greeting.last_result;
                for(const attr of ['audio','download','assign'])item.querySelector(`[data-greeting-${attr}]`).hidden=greeting.state!=='ready';
                item.querySelector('[data-greeting-cancel]').hidden=!['pending','preparing','ready_to_call'].includes(greeting.state);
                item.querySelector('[data-greeting-retry]').hidden=greeting.state!=='failed';
                item.querySelector('[data-greeting-archive]').hidden=!['ready','failed','cancelled'].includes(greeting.state);
            }
        }catch(_){}finally{setTimeout(status,5000);}
    }
    if(document.querySelector('[data-create-greeting]'))setTimeout(status,5000);
})();
