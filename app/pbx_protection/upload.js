'use strict';
const form=document.getElementById('backup-upload');
if(form)form.addEventListener('submit',async event=>{
    event.preventDefault();const button=form.querySelector('button'),result=document.getElementById('backup-upload-result');
    const file=form.elements.backup.files[0];if(!file||file.size<52||file.size>2147483648){result.textContent='Choose an encrypted backup up to 2 GB.';return;}
    button.disabled=true;result.textContent='Uploading encrypted copy. Keep this page open.';
    try{
        const password=btoa(String.fromCharCode(...new TextEncoder().encode(form.elements.password.value)));
        const response=await fetch('/app/pbx_protection/upload.php?tenant='+encodeURIComponent(form.dataset.tenant),{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/octet-stream','X-OpenWeb-Token-Name':form.dataset.tokenName,'X-OpenWeb-Token':form.dataset.token,'X-Backup-Password':password},body:file});
        const data=await response.json();if(!response.ok)throw new Error((typeof data.error==='string'?data.error:data.error?.message)||'Upload failed.');
        form.elements.password.value='';form.elements.backup.value='';result.textContent=data.message+' Refresh results in a moment.';
    }catch(error){result.textContent=error.message||'The upload failed. Retry after checking the connection.';}finally{button.disabled=false;}
});
