using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;

internal static class OnboardingChecks
{
    private static string Encode(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static string Envelope(Dictionary<string, object?> payload, RSA key)
    {
        var raw = JsonSerializer.SerializeToUtf8Bytes(payload);
        return JsonSerializer.Serialize(new { key_id = OnboardingGate.KeyId, algorithm = "RS256", payload = Encode(raw),
            signature = Encode(key.SignData(raw, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)) });
    }
    private static Dictionary<string, object?> Payload(DateTimeOffset now, IReadOnlyDictionary<string, string> bindings) => new()
    {
        ["schema"] = 1, ["issuer"] = OnboardingGate.Issuer, ["audience"] = "openwebpbx-installation",
        ["installation_uuid"] = Guid.NewGuid().ToString("D"), ["account_tenant_uuid"] = bindings["account_tenant_uuid"],
        ["local_tenant_uuid"] = bindings["local_tenant_uuid"], ["domain_uuid"] = bindings["domain_uuid"],
        ["key_hash"] = bindings["key_hash"], ["server_host"] = bindings["server_host"], ["label"] = bindings["label"],
        ["issued_at"] = now.AddSeconds(-10).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
        ["expires_at"] = now.AddDays(365).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"), ["generation"] = 1
    };
    public static int Pure()
    {
        var count = 0; var now = DateTimeOffset.UtcNow;
        using var key = RSA.Create(3072); var pem = key.ExportSubjectPublicKeyInfoPem();
        var bindings = new Dictionary<string, string> { ["account_tenant_uuid"] = Guid.NewGuid().ToString("D"),
            ["local_tenant_uuid"] = Guid.NewGuid().ToString("D"), ["domain_uuid"] = Guid.NewGuid().ToString("D"),
            ["key_hash"] = new string('a', 64), ["server_host"] = "node-example.openwebpbx.com", ["label"] = "example-company" };
        var p = Payload(now, bindings); var good = Envelope(p, key);
        OnboardingGate.VerifyReceipt(good, pem, bindings, now); count++;
        void Refuse(string value, string publicKey, IReadOnlyDictionary<string,string> expected, string label)
        {
            try { OnboardingGate.VerifyReceipt(value, publicKey, expected, now); }
            catch (Exception ex) when (ex is InvalidDataException or JsonException or CryptographicException or FormatException or InvalidOperationException or ArgumentException) { count++; return; }
            throw new Exception("Onboarding accepted " + label);
        }
        foreach (var field in p.Keys)
        {
            var missing = new Dictionary<string, object?>(p); missing.Remove(field);
            Refuse(Envelope(missing, key), pem, bindings, "missing " + field);
        }
        foreach (var pair in bindings)
        {
            var expected = new Dictionary<string,string>(bindings) { [pair.Key] = pair.Key.Contains("uuid") ? Guid.NewGuid().ToString("D") : "foreign" };
            Refuse(good, pem, expected, "foreign binding " + pair.Key);
        }
        foreach (var change in new (string Key, object? Value)[] {
            ("schema",2), ("issuer","https://foreign.example.invalid"), ("audience","other"), ("installation_uuid","invalid"),
            ("generation",0), ("generation",true), ("issued_at",now.AddMinutes(6).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")),
            ("expires_at",now.AddSeconds(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")),
            ("expires_at",now.AddDays(368).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")), ("issued_at","2026-02-30T00:00:00Z"),
            ("expires_at","2099-01-01T00:00:00+02:00") })
        {
            var changed = new Dictionary<string,object?>(p) { [change.Key] = change.Value };
            Refuse(Envelope(changed,key),pem,bindings,"invalid "+change.Key);
        }
        var extra = new Dictionary<string,object?>(p) { ["extra"] = "untrusted" }; Refuse(Envelope(extra,key),pem,bindings,"unknown payload field");
        using var wrong = RSA.Create(3072); Refuse(good,wrong.ExportSubjectPublicKeyInfoPem(),bindings,"foreign signer");
        using var weak = RSA.Create(2048); Refuse(Envelope(p,weak),weak.ExportSubjectPublicKeyInfoPem(),bindings,"undersized signer");
        var envelope = JsonSerializer.Deserialize<Dictionary<string,string>>(good)!;
        foreach (var pair in new[] { new KeyValuePair<string,string>("algorithm","none"), new("key_id","foreign"), new("signature","AA"), new("payload",envelope["payload"]+"=") })
        {
            var changed = new Dictionary<string,string>(envelope) { [pair.Key] = pair.Value };
            Refuse(JsonSerializer.Serialize(changed),pem,bindings,"invalid envelope "+pair.Key);
        }
        foreach (var field in new[] { "payload", "signature" })
        {
            var changed = envelope.ToDictionary(p => p.Key, p => (object?)p.Value); changed[field] = null;
            Refuse(JsonSerializer.Serialize(changed),pem,bindings,"null envelope "+field);
        }
        var duplicate = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(p).TrimEnd('}') + ",\"schema\":1}");
        Refuse(JsonSerializer.Serialize(new { key_id=OnboardingGate.KeyId, algorithm="RS256", payload=Encode(duplicate), signature=Encode(key.SignData(duplicate,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1)) }),pem,bindings,"duplicate signed field");
        Console.WriteLine($"PASS: {count} signed installation-grant controls");
        return count;
    }

    public static async Task<int> Database(string connection, SwitchClient engine, System.Collections.Concurrent.ConcurrentBag<string> commands)
    {
        var count = 0; var schema = "onboarding_native_" + Guid.NewGuid().ToString("N");
        var temporary = Path.Combine(Path.GetTempPath(),schema); Directory.CreateDirectory(temporary);
        var state = Path.Combine(temporary,"state"); var web = Path.Combine(temporary,"web");
        Directory.CreateDirectory(Path.Combine(state,"tenant-domains")); Directory.CreateDirectory(Path.Combine(web,"resources","keys"));
        await using var owner = NpgsqlDataSource.Create(connection); await using var control = await owner.OpenConnectionAsync();
        await using var create = new NpgsqlCommand("create schema "+schema,control); await create.ExecuteNonQueryAsync();
        try
        {
            await using var data = NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder(connection) { SearchPath=schema }.ConnectionString);
            await using var db = await data.OpenConnectionAsync();
            async Task Sql(string sql) {await using var command=new NpgsqlCommand(sql,db);await command.ExecuteNonQueryAsync();}
            void Check(bool value,string label) {if(!value)throw new Exception(label);count++;}
            var domain=Guid.NewGuid();var tenant=Guid.NewGuid();var service=Guid.NewGuid();var user=Guid.NewGuid();var account=Guid.NewGuid();
            var oldConfiguration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?> { ["Onboarding:StateRoot"]=state,["Onboarding:WebRoot"]=web }).Build();
            var legacy = new OnboardingGate(oldConfiguration);
            Check((await legacy.Read(db,default)).Allows(domain),"Old installation missing onboarding tables was blocked");
            await Sql("""
                create table v_domains(domain_uuid uuid primary key,domain_enabled text);
                create table v_users(user_uuid uuid primary key,user_enabled text);
                create table v_pbx_tenants(tenant_uuid uuid primary key,owner_user_uuid uuid,enabled boolean);
                create table v_pbx_services(service_uuid uuid primary key,tenant_uuid uuid,domain_uuid uuid unique);
                """);
            await Sql(await File.ReadAllTextAsync("app/pbx_onboarding/resources/install.sql"));
            await Sql(await File.ReadAllTextAsync("app/pbx_tenant_domains/resources/install.sql"));
            Check((await legacy.Read(db,default)).Allows(domain),"Migration enabled onboarding on an old installation");
            var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?> { ["Onboarding:Required"]="true",["Onboarding:StateRoot"]=state,["Onboarding:WebRoot"]=web }).Build();
            var gate=new OnboardingGate(config); Check(!(await gate.Read(db,default)).Allows(domain)&&gate.RegistrationRequired,"Fresh unregistered installation allowed calling");
            var setup=Path.Combine(state,"tenant-domains","setup.json");
            var setupUntil=DateTimeOffset.UtcNow.AddMinutes(10).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
            File.WriteAllText(setup,JsonSerializer.Serialize(new { user_code="A1B2C-D3E4F",verification_uri_complete="https://openwebpbx.com/wizard#code=A1B2C-D3E4F",expires_at=setupUntil }));
            Check(gate.Setup()?.UserCode=="A1B2C-D3E4F","The owned setup code was unavailable");
            var setupOriginal=File.ReadAllText(setup);File.WriteAllText(setup,setupOriginal.Replace("https://openwebpbx.com/","https://foreign.example.invalid/"));
            Check(gate.Setup() is null,"A foreign setup link was published");File.WriteAllText(setup,setupOriginal.Replace(setupUntil,"2000-01-01T00:00:00Z"));
            Check(gate.Setup() is null,"An expired setup code was published");File.WriteAllText(setup,setupOriginal);
            await Sql($"insert into v_domains values('{domain}','true');insert into v_users values('{user}','true');insert into v_pbx_tenants values('{tenant}','{user}',true);insert into v_pbx_services values('{service}','{tenant}','{domain}')");
            using var instance=ECDsa.Create(ECCurve.NamedCurves.nistP256);var publicKey=instance.ExportSubjectPublicKeyInfo();var hash=Convert.ToHexStringLower(SHA256.HashData(publicKey));
            const string host="node-native-check.openwebpbx.com",label="native-company",alias="native-company.openwebpbx.com";
            await Sql($"update v_pbx_onboarding_policy set required=true,canonical_host='{host}',instance_key_hash='{hash}' where singleton=true");
            void Write(string path,string value) {File.WriteAllText(path,value);if(!OperatingSystem.IsWindows())File.SetUnixFileMode(path,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.GroupRead);}
            var identity=Path.Combine(state,"tenant-domains","instance-public.json");var ready=Path.Combine(state,"tenant-domains","ready.json");var pemPath=Path.Combine(web,"resources","keys","installation-authority.pem");
            Write(identity,JsonSerializer.Serialize(new{schema=1,server_host=host,key_hash=hash,public_key=Convert.ToBase64String(publicKey)}));
            using var key=RSA.Create(3072);Write(pemPath,key.ExportSubjectPublicKeyInfoPem());
            var bindings=new Dictionary<string,string>{["account_tenant_uuid"]=account.ToString("D"),["local_tenant_uuid"]=tenant.ToString("D"),["domain_uuid"]=domain.ToString("D"),["key_hash"]=hash,["server_host"]=host,["label"]=label};
            var envelope=Envelope(Payload(DateTimeOffset.UtcNow,bindings),key);
            await using(var insert=new NpgsqlCommand("insert into v_pbx_onboarding(domain_uuid,tenant_uuid,service_uuid,owner_user_uuid,account_tenant_uuid,requested_label,server_host,key_hash,state,activation,grant_expires_at)values($1,$2,$3,$4,$5,$6,$7,$8,'ready',$9::jsonb,now()+interval '1 year')",db)){
                foreach(var value in new object[]{domain,tenant,service,user,account,label,host,hash,envelope})insert.Parameters.AddWithValue(value);await insert.ExecuteNonQueryAsync();}
            Check(!(await gate.Read(db,default)).Allows(domain),"A valid grant without ready HTTPS allowed calling");
            await Sql($"insert into v_pbx_tenant_domains(domain_uuid,tenant_uuid,service_uuid,requested_label,hostname,server_host,key_hash,revision,state,desired_enabled,certificate_not_after)values('{domain}','{tenant}','{service}','{label}','{alias}','{host}','{hash}',1,'ready',true,now()+interval '1 day')");
            var until=DateTimeOffset.UtcNow.AddDays(1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
            Write(ready,JsonSerializer.Serialize(new{schema=1,server_host=host,key_hash=hash,aliases=new Dictionary<string,string>{{alias,until}},authorizations=new Dictionary<string,object>()}));
            var access=await gate.Read(db,default);Check(access.Allows(domain)&&!gate.RegistrationRequired,"Valid grant and verified owned transport were refused");
            Check(gate.Setup() is null,"A completed installation continued publishing its setup code");
            var currentTransport=File.ReadAllText(ready);
            Write(ready,JsonSerializer.Serialize(new{schema=1,server_host=host,key_hash=hash,aliases=new Dictionary<string,string>{{alias,until}}}));
            Check((await gate.Read(db,default)).Allows(domain),"A prior transport snapshot shape was refused");Write(ready,currentTransport);
            await Sql(await File.ReadAllTextAsync("app/pbx_setup/resources/jobs.sql"));
            var foreignDomain=Guid.NewGuid();var grantedJob=Guid.NewGuid();var foreignJob=Guid.NewGuid();
            await Sql($"insert into v_domains values('{foreignDomain}','true');insert into v_pbx_jobs(job_uuid,domain_uuid,kind,target_number,request_key)values('{grantedJob}','{domain}','callback','100','registered'),('{foreignJob}','{foreignDomain}','callback','101','unregistered')");
            var worker=new JobWorker(data,engine,new ServiceStatus(),NullLogger<JobWorker>.Instance,gate);
            await worker.Tick(default);
            await using(var observed=new NpgsqlCommand("select job_uuid,state from v_pbx_jobs order by job_uuid",db))
            await using(var rows=await observed.ExecuteReaderAsync())while(await rows.ReadAsync()){
                Check(rows.GetString(1)==(rows.GetGuid(0)==grantedJob?"starting":"waiting"),"The registered-domain job filter leased the wrong work");}
            Check(commands.Count(c=>c=="api luarun app/pbx_setup/jobs.lua "+grantedJob.ToString("D"))==1,"A registered tenant's call was not dispatched exactly once");
            Check(!commands.Any(c=>c.Contains(foreignJob.ToString("D"),StringComparison.Ordinal)),"An unregistered tenant's call was dispatched");
            Check((await legacy.Read(db,default)).Allows(domain),"A valid required database policy was ignored when runtime flag was absent");
            Check(!access.Allows(Guid.NewGuid()),"An unrelated tenant used another domain's grant");
            await Sql("update v_pbx_onboarding_policy set canonical_host='foreign.example.invalid'");Check(!(await gate.Read(db,default)).Allows(domain),"A policy/instance identity mismatch was accepted");await Sql($"update v_pbx_onboarding_policy set canonical_host='{host}'");
            await Sql($"update v_domains set domain_enabled='false' where domain_uuid='{domain}'");Check(!(await gate.Read(db,default)).Allows(domain),"Disabled domain was accepted");await Sql($"update v_domains set domain_enabled='true' where domain_uuid='{domain}'");
            await Sql($"update v_users set user_enabled='false' where user_uuid='{user}'");Check(!(await gate.Read(db,default)).Allows(domain),"Disabled owner was accepted");await Sql($"update v_users set user_enabled='true' where user_uuid='{user}'");
            await Sql($"update v_pbx_tenants set enabled=false where tenant_uuid='{tenant}'");Check(!(await gate.Read(db,default)).Allows(domain),"Suspended tenant was accepted");await Sql($"update v_pbx_tenants set enabled=true where tenant_uuid='{tenant}'");
            await Sql("update v_pbx_tenant_domains set desired_enabled=false");Check(!(await gate.Read(db,default)).Allows(domain),"Disabled managed domain lease was accepted");await Sql("update v_pbx_tenant_domains set desired_enabled=true");
            await Sql($"update v_pbx_tenant_domains set tenant_uuid='{Guid.NewGuid()}'");Check(!(await gate.Read(db,default)).Allows(domain),"Another tenant's transport lease was accepted");await Sql($"update v_pbx_tenant_domains set tenant_uuid='{tenant}'");
            await Sql("update v_pbx_tenant_domains set certificate_not_after=now()-interval '1 second'");Check(!(await gate.Read(db,default)).Allows(domain),"Expired tenant certificate was accepted");await Sql("update v_pbx_tenant_domains set certificate_not_after=now()+interval '1 day'");
            var original=File.ReadAllText(ready);Write(ready,original.Replace(until,"2000-01-01T00:00:00Z"));Check(!(await gate.Read(db,default)).Allows(domain),"Expired local transport marker was accepted");Write(ready,original);
            if(!OperatingSystem.IsWindows()) {File.SetUnixFileMode(ready,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.GroupWrite);Check(!(await gate.Read(db,default)).Allows(domain),"Writable local transport marker was accepted");Write(ready,original);}
            await Sql("update v_pbx_onboarding set activation=jsonb_set(activation,'{signature}','\"AA\"'::jsonb)");Check(!(await gate.Read(db,default)).Allows(domain),"Forged database ready state authorized a call");
            Check(!(await legacy.Read(db,default)).Allows(domain)&&legacy.RegistrationRequired,"Required database policy became optional after removing the runtime flag");
            Console.WriteLine($"PASS: {count} isolated PostgreSQL installation-gate controls");
            return count;
        }
        finally
        {
            await using var drop=new NpgsqlCommand("drop schema "+schema+" cascade",control);await drop.ExecuteNonQueryAsync();
            Directory.Delete(temporary,true);
        }
    }
}
