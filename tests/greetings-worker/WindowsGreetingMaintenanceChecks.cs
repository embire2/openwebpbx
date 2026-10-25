using System.Net;
using System.Net.Sockets;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;

static class WindowsGreetingMaintenanceChecks
{
    public static async Task<int> Run()
    {
        if (!OperatingSystem.IsWindows()) return 0;
        var directory=Path.Combine(Path.GetTempPath(),"greeting-maintenance-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(directory);
        var lockPath=Path.Combine(directory,"upgrade.lock");var holdPath=Path.Combine(directory,"call-records.hold");
        File.WriteAllText(lockPath,"");
        using var stop=new CancellationTokenSource();
        var database=new TcpListener(IPAddress.Loopback,0);database.Start();
        var dispatch=new TcpListener(IPAddress.Loopback,0);dispatch.Start();
        int databaseConnections=0,dispatchConnections=0,httpRequests=0,checks=0;
        var databaseObserved=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task Observe(TcpListener listener,bool db)
        {
            while(!stop.IsCancellationRequested){
                TcpClient client;try{client=await listener.AcceptTcpClientAsync(stop.Token);}catch(OperationCanceledException){return;}
                catch(Exception error)when(stop.IsCancellationRequested&&(error is SocketException or ObjectDisposedException or InvalidOperationException)){return;}
                using(client){if(db){Interlocked.Increment(ref databaseConnections);databaseObserved.TrySetResult();}else Interlocked.Increment(ref dispatchConnections);}
            }
        }
        var dbObserver=Observe(database,true);var dispatchObserver=Observe(dispatch,false);
        using var http=new HttpClient(new CountingHandler(()=>Interlocked.Increment(ref httpRequests)));
        await using var data=NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder {
            Host="127.0.0.1",Port=((IPEndPoint)database.LocalEndpoint).Port,Database="owned_refusal_fixture",Username="owned_fixture",
            Password="not-a-production-secret",SslMode=SslMode.Disable,Timeout=1,CommandTimeout=1,Pooling=false
        }.ConnectionString);
        var config=new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?> {
            ["Greetings:StateRoot"]=directory,["Greetings:MediaRoot"]=Path.Combine(directory,"must-not-create-media"),
            ["ElevenLabs:ApiKey"]="owned-fixture-key",["Switch:Host"]="127.0.0.1",
            ["Switch:Port"]=((IPEndPoint)dispatch.LocalEndpoint).Port.ToString(),["Switch:Password"]="owned-fixture"
        }).Build();
        var worker=new GreetingWorker(data,new CountingFactory(http),config,new SwitchClient(config),NullLogger<GreetingWorker>.Instance);
        void Check(bool value,string message){if(!value)throw new Exception(message);checks++;}
        async Task RefusesBeforeIo(string label)
        {
            await worker.Tick(default);
            Check(Volatile.Read(ref databaseConnections)==0,label+": database connection attempted");
            Check(Volatile.Read(ref httpRequests)==0,label+": HTTP request attempted");
            Check(Volatile.Read(ref dispatchConnections)==0,label+": call dispatch attempted");
            Check(!Directory.Exists(config["Greetings:MediaRoot"]),label+": media written");
        }
        try {
            // Real Windows kernel sharing, not a mocked FileStream or a POSIX approximation.
            using(var exclusive=new FileStream(lockPath,FileMode.Open,FileAccess.ReadWrite,FileShare.None)){
                await RefusesBeforeIo("Exclusive native upgrade lock");
                await RefusesBeforeIo("Repeated tick under exclusive lock");
                Check(exclusive.Length==0,"Maintenance changed the owned upgrade lock");
            }
            File.WriteAllText(holdPath,"owned durable fixture hold");
            await RefusesBeforeIo("Durable maintenance hold");
            Check(File.ReadAllText(holdPath)=="owned durable fixture hold","Durable hold was altered");
            File.Delete(holdPath);
            // A real negative control proves the counted listener observes a DB
            // attempt when the maintenance lease is available again.
            var refused=false;
            try{await worker.Tick(default);}catch(Exception error)when(error is NpgsqlException or IOException or TimeoutException){refused=true;}
            await databaseObserved.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check(refused&&Volatile.Read(ref databaseConnections)>0,"Released lease did not reach the rejecting database observer");
            Check(Volatile.Read(ref httpRequests)==0&&Volatile.Read(ref dispatchConnections)==0,"Rejecting DB allowed later HTTP or dispatch");
            using(var exclusive=new FileStream(lockPath,FileMode.Open,FileAccess.ReadWrite,FileShare.None))Check(exclusive.Length==0,"Worker leaked its shared maintenance lease");
        } finally {
            stop.Cancel();database.Stop();dispatch.Stop();await Task.WhenAll(dbObserver,dispatchObserver);Directory.Delete(directory,true);
        }
        return checks;
    }
    private sealed class CountingFactory(HttpClient client):IHttpClientFactory { public HttpClient CreateClient(string name)=>client; }
    private sealed class CountingHandler(Action called):HttpMessageHandler {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct){called();return Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError));}
    }
}
