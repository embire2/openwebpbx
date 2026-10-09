using Npgsql;
using OpenWebPbx.Server;

var builder = WebApplication.CreateBuilder(args);
var settingsPath = Environment.GetEnvironmentVariable("OPENWEBPBX_CONFIG");
if (string.IsNullOrEmpty(settingsPath))
{
    var defaultPath = OperatingSystem.IsWindows()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX", "runtime.json")
        : "/etc/openwebpbx/runtime.json";
    if (File.Exists(defaultPath)) settingsPath = defaultPath;
}
if (!string.IsNullOrEmpty(settingsPath)) builder.Configuration.AddJsonFile(settingsPath, optional: false, reloadOnChange: false);
builder.Services.AddWindowsService(options => options.ServiceName = "OpenWebPBX");
builder.Services.AddSingleton<ServiceStatus>();
builder.Services.AddSingleton<SwitchClient>();
var connection = builder.Configuration.GetConnectionString("Pbx");
if (!string.IsNullOrWhiteSpace(connection))
{
    builder.Services.AddSingleton(NpgsqlDataSource.Create(connection));
    builder.Services.AddHostedService<JobWorker>();
}
// This local service has no public administrative routes. The PBX web console retains
// authentication, permissions, tenant checks and form tokens for every user action.
builder.WebHost.UseUrls("http://127.0.0.1:8087");
var app = builder.Build();
app.MapGet("/health", (ServiceStatus status) => Results.Json(new
{
    application = "OpenWeb PBX", version = typeof(Program).Assembly.GetName().Version?.ToString(3),
    state = string.IsNullOrWhiteSpace(connection) ? "Setup required" : status.State,
    lastSuccess = status.LastSuccess,
    operatingSystem = OperatingSystem.IsWindows() ? "Windows" : "Linux"
}));
app.Run();
