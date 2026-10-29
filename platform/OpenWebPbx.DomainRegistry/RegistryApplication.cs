// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Text.Json;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.RateLimiting;
using Npgsql;
using System.Net;
using Microsoft.AspNetCore.HttpOverrides;
namespace OpenWebPbx.DomainRegistry;
public static class RegistryApplication {
    public static WebApplication Create(string[] args, RegistryOptions options, Action<IServiceCollection>? configure = null) {
        var builder = WebApplication.CreateBuilder(args); builder.WebHost.UseUrls(options.ListenUrl);
        builder.WebHost.ConfigureKestrel(server => server.Limits.MaxRequestBodySize = 4096);
        builder.Logging.AddFilter("System.Net.Http", LogLevel.Warning);
        builder.Services.ConfigureHttpJsonOptions(value => { value.SerializerOptions.UnmappedMemberHandling = System.Text.Json.Serialization.JsonUnmappedMemberHandling.Disallow; value.SerializerOptions.MaxDepth = 8; });
        builder.Services.AddSingleton(options); builder.Services.AddSingleton(_ => NpgsqlDataSource.Create(options.ConnectionString));
        builder.Services.AddSingleton<RegistryStore>(); builder.Services.AddSingleton<ISiteProof, PublicSiteProof>(); builder.Services.AddSingleton<IRegistryDns, CpanelDns>();
        builder.Services.AddSingleton<InstallationAuthorization>();builder.Services.AddSingleton<IBootstrapProof,BootstrapProof>();builder.Services.AddSingleton<InstanceBootstrap>();
        builder.Services.AddSingleton<TenantReservations>();
        builder.Services.AddSingleton<InstanceOperations>();
        builder.Services.Configure<ForwardedHeadersOptions>(value => {
            value.ForwardedHeaders = ForwardedHeaders.XForwardedFor; value.ForwardLimit = 1;
            value.KnownIPNetworks.Clear(); value.KnownProxies.Clear();
            value.KnownProxies.Add(IPAddress.Loopback); value.KnownProxies.Add(IPAddress.IPv6Loopback);
        });
        builder.Services.AddRateLimiter(rate => {
            rate.RejectionStatusCode = 429;
            rate.OnRejected = (context, _) => { context.HttpContext.Response.Headers.RetryAfter = "60"; return ValueTask.CompletedTask; };
            rate.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(context => RateLimitPartition.GetFixedWindowLimiter(context.Connection.RemoteIpAddress?.ToString() ?? "unknown", _ => new FixedWindowRateLimiterOptions { PermitLimit = 120, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
        });
        configure?.Invoke(builder.Services); var app = builder.Build();
        app.UseForwardedHeaders();
        app.Use(async (context, next) => {
            context.Response.Headers.CacheControl = "no-store";
            var callerStop = context.RequestAborted;
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(callerStop);
            deadline.CancelAfter(TimeSpan.FromSeconds(40)); context.RequestAborted = deadline.Token;
            try { await next(context); }
            catch (Refused error) { app.Logger.LogWarning("Registry refusal {Category} trace {Trace}", error.Message, context.TraceIdentifier); context.Response.StatusCode = error.Status; await context.Response.WriteAsJsonAsync(new { error = error.Message }, callerStop); }
            catch (BadHttpRequestException) { context.Response.StatusCode = 400; await context.Response.WriteAsJsonAsync(new { error = "invalid_request" }); }
            catch (OperationCanceledException) when (!callerStop.IsCancellationRequested) { app.Logger.LogWarning("Registry deadline trace {Trace}", context.TraceIdentifier); context.Response.StatusCode = 503; context.Response.Headers.RetryAfter = "300"; await context.Response.WriteAsJsonAsync(new { error = "registry_deadline" }, callerStop); }
            catch (Exception error) when (error is not OperationCanceledException) { app.Logger.LogWarning("Registry unavailable {ErrorType} trace {Trace}", error.GetType().Name, context.TraceIdentifier); context.Response.StatusCode = 503; context.Response.Headers.RetryAfter = "300"; await context.Response.WriteAsJsonAsync(new { error = "registry_temporarily_unavailable" }, callerStop); }
            finally { context.RequestAborted = callerStop; }
        });
        app.UseRateLimiter(); app.MapGet("/health", () => new { service = "openwebpbx-domain-registry", protocol = 1 });
        static void Internal(HttpContext context){
            if(context.Connection.RemoteIpAddress is null || !IPAddress.IsLoopback(context.Connection.RemoteIpAddress)
                || context.Request.Host.Host!="127.0.0.1" || context.Request.Host.Port!=context.Connection.LocalPort)throw new Refused("internal_route_unavailable",404);
        }
        app.MapPost("/internal/v1/verify-instance-proof",async(InstanceProofRequest value,HttpContext context,ISiteProof proof,CancellationToken stop)=>{
            Internal(context);if(value.Nonce is not { Length:64 } nonce || value.KeyHash is not { Length:64 } hash || !System.Text.RegularExpressions.Regex.IsMatch(nonce,"^[0-9a-f]{64}$")||!System.Text.RegularExpressions.Regex.IsMatch(hash,"^[0-9a-f]{64}$"))throw new Refused("invalid_proof_request");
            await proof.Verify(value.ServerHost,nonce,hash,stop);return new{verified=true};
        });
        app.MapPost("/internal/v1/bootstrap-instance",async(BootstrapRequest value,HttpContext context,InstanceBootstrap bootstrap,CancellationToken stop)=>{Internal(context);return await bootstrap.Register(value,stop);});
        app.MapPost("/internal/v1/label-availability",async(LabelAvailabilityRequest value,HttpContext context,TenantReservations reservations,CancellationToken stop)=>{Internal(context);return await reservations.Availability(value.Label,stop);});
        app.MapPost("/internal/v1/reserve-label",async(LabelReservationRequest value,HttpContext context,TenantReservations reservations,CancellationToken stop)=>{Internal(context);return await reservations.Reserve(value,stop);});
        app.MapPost("/internal/v1/renew-label",async(LabelReservationAction value,HttpContext context,TenantReservations reservations,CancellationToken stop)=>{Internal(context);return await reservations.Action(value,false,stop);});
        app.MapPost("/internal/v1/release-label",async(LabelReservationAction value,HttpContext context,TenantReservations reservations,CancellationToken stop)=>{Internal(context);return await reservations.Action(value,true,stop);});
        app.MapPost("/internal/v1/bind-label",async(LabelReservationBind value,HttpContext context,TenantReservations reservations,CancellationToken stop)=>{Internal(context);return await reservations.Bind(value,stop);});
        app.MapPost("/internal/v1/revoke-instance",async(InstanceRevokeRequest value,HttpContext context,TenantReservations reservations,CancellationToken stop)=>{Internal(context);return await reservations.Revoke(value,stop);});
        app.MapPost("/internal/v1/verify-tenant-ready",async(TenantReadyRequest value,HttpContext context,RegistryStore store,ISiteProof proof,CancellationToken stop)=>{
            Internal(context);if(value.Nonce is not { Length:64 } nonce || value.KeyHash is not { Length:64 } hash || !System.Text.RegularExpressions.Regex.IsMatch(nonce,"^[0-9a-f]{64}$")||!System.Text.RegularExpressions.Regex.IsMatch(hash,"^[0-9a-f]{64}$")||value.DomainUuid==Guid.Empty||!await store.TenantReadyBinding(value,stop))throw new Refused("tenant_readiness_unavailable",403);
            await proof.VerifyTenantAlias(value.Hostname,value.ServerHost,nonce,hash,stop);return new{verified=true};
        });
        // Public ownership lookup contains no keys or credentials. Android uses
        // this trusted origin before moving an existing bearer to a tenant URL.
        app.MapGet("/v1/tenant-addresses/{hostname}", async (string hostname, RegistryStore store, CancellationToken stop) =>
            await store.TenantAddress(hostname, stop));
        app.MapPost("/v1/challenges", async (ChallengeRequest request, RegistryStore store, CancellationToken stop) => await store.Challenge(Protocol.KeyHash(request.PublicKey), Protocol.Host(request.ServerHost), stop));
        app.MapPost("/v1/leases", async (LeaseRequest request, RegistryStore store, ISiteProof proof, IRegistryDns dns, HttpRequest http,InstallationAuthorization verifier,InstanceBootstrap bootstrap,InstanceOperations operations, CancellationToken stop) => {
            if (request.Move && http.Headers.IfMatch.ToString() != "\"" + request.Revision + "\"") throw new Refused("host_move_if_match_required", 409);
            var hash = Protocol.Verify(request);
            var address=await operations.AddressFor(hash,request.ServerHost,stop);
            await using var addressGuard=address is null?null:await operations.Address(address,stop);
            await using var instanceGuard=await operations.Key(hash,stop);
            await store.CheckChallenge(request.Challenge, hash, request.ServerHost, stop);
            await proof.Verify(request.ServerHost, request.Challenge, hash, stop);
            var activation=request.Authorization is null?null:verifier.Verify(request.Authorization,request,hash);
            if(activation is not null&&!await bootstrap.Matches(request,hash,activation,stop))throw new Refused("bootstrap_instance_binding",403);
            var existing = await dns.Names(stop); var lease = await store.Reserve(request, hash, existing, stop,activation);
            LeaseReply Reply(string state) => new(lease.Label + "." + RegistryOptions.Zone, request.ServerHost, state, request.Enabled, lease.Revision);
            if (!request.Enabled) return Reply("disabled");
            try { await dns.Ensure(lease.Label, request.ServerHost, lease.DnsHost, stop); await store.Ready(hash, request.DomainUuid, request.ServerHost, lease.Revision, stop); return Reply("dns_ready"); }
            catch (Refused error) when (error.Message == "dns_conflict") { return Reply("dns_conflict"); }
            catch (Exception error) when (error is HttpRequestException or IOException or JsonException) { return Reply("pending_dns"); }
        });
        return app;
    }
}
