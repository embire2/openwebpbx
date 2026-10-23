// SPDX-License-Identifier: AGPL-3.0-or-later
using OpenWebPbx.Phone.MediaChecks;
try
{
    Protocol.Guard();
    if (args.Length == 2 && args[0] == "--peer") return PeerRunner.Run(args[1]);
    if (args.Length == 3 && args[0] == "--run") return LabCoordinator.Run(args[1], args[2]);
    throw new InvalidOperationException("Use only the hosted media wrapper.");
}
catch (Exception error)
{
    Console.Error.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { schema = 1, state = "refused_or_failed", error_type = error.GetType().Name })); return 2;
}
