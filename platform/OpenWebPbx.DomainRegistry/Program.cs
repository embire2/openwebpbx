using OpenWebPbx.DomainRegistry;
var path = Environment.GetEnvironmentVariable("OPENWEB_DOMAIN_REGISTRY_CONFIG") ?? "/etc/openwebpbx-domain-registry/config.json";
var options = RegistryOptions.Read(path);
var app = RegistryApplication.Create(args, options);
await app.Services.GetRequiredService<RegistryStore>().Initialize(default);
app.Run();
