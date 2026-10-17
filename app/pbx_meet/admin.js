document.querySelector('input[name=local_start]')?.form.addEventListener('submit',event=>{const form=event.currentTarget;const value=form.elements.local_start.value;form.elements.starts_at.value=value?new Date(value).toISOString():'';});
document.querySelectorAll('time[datetime]').forEach(el=>{const time=new Date(el.dateTime);if(!isNaN(time))el.textContent=time.toLocaleString();});
