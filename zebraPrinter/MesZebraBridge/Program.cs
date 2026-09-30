// TEMPORARY ENTRY POINT -- replaced wholesale by Task 12 of
// docs/superpowers/plans/2026-09-30-meszebrabridge-csharp-service.md, which is
// where the real verb dispatch (install / set-queue / uninstall / run / status /
// detect) lands.
//
// It exists only because the project is OutputType=Exe from Task 1 while the real
// Program.cs is not written until Task 12: without SOME static Main the C# compiler
// fails the whole project with CS5001, which would make every `dotnet test` run in
// Tasks 1-11 a compile error rather than a test result. The plan did not account
// for that ordering.
//
// Nothing references this. Deleting it before Task 12 re-breaks the build.

using System;

namespace BlueRidge.MesZebraBridge
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            Console.Error.WriteLine(
                "MesZebraBridge is still under construction -- no verb is implemented yet. "
                + "See docs/superpowers/plans/2026-09-30-meszebrabridge-csharp-service.md.");
            return 2;
        }
    }
}
