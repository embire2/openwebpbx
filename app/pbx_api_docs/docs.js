'use strict';
// Local filtering only. No credentials, tracking or live API requests.
const filter=document.getElementById('endpoint-filter'),counter=document.getElementById('endpoint-count'),endpoints=[...document.querySelectorAll('[data-endpoint]')];
filter?.addEventListener('input',()=>{const words=filter.value.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);let visible=0;for(const item of endpoints){item.hidden=!words.every(word=>item.textContent.toLocaleLowerCase().includes(word));if(!item.hidden)visible++;}counter.textContent=`${visible} of ${endpoints.length} operations`;});
