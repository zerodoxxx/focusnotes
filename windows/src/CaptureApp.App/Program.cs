using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using CaptureApp.Overlay;
using CaptureApp.AppCore;
using CaptureApp.Core;
using CaptureApp.Updates;
using Velopack;

namespace CaptureApp.App;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        // vpk pack scans this exe for the literal call, so it stays here rather than in the Updates assembly.
        VelopackApp.Build().OnFirstRun(_ => UpdateBootstrap.MarkFirstRun()).Run();

#if CI_UPDATE_TESTS
        if (args.Length > 0 && string.Equals(args[0], "--ci-update", StringComparison.Ordinal))
        {
            AttachConsoleIfNeeded();
            return CiUpdateCommand.RunAsync(args).GetAwaiter().GetResult();
        }
#endif

        if (args.Length > 0 && string.Equals(args[0], "--self-test", StringComparison.Ordinal))
        {
            AttachConsoleIfNeeded();
            try
            {
                if (args.Length != 2 && (args.Length != 4 || !string.Equals(args[2], "--models", StringComparison.Ordinal)))
                {
                    throw new ArgumentException("Usage: --self-test <dir> [--models <dir>]");
                }

                SelfTest.RunAsync(args[1], args.Length == 4 ? args[3] : null, extension: AppSelfTest.RunAsync).GetAwaiter().GetResult();
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine($"Self-test failed: {error}");
                return 1;
            }
        }

        if (args.Contains("--version", StringComparer.Ordinal))
        {
            AttachConsoleIfNeeded();
            Console.WriteLine(AppInfo.Version);
            return 0;
        }

        return RunApp();
    }

    private static int RunApp()
    {
        var state = StatePaths.DefaultDirectory();
        AppController? controller = null;
        SingleInstance? instance;
        try
        {
            instance = SingleInstance.StartAsync(state, () => controller?.ShowRequested()).GetAwaiter().GetResult();
        }
        catch (IOException error)
        {
            new AppLog(state, "startup").Error($"Single-instance check failed: {error.Message}");
            return 1;
        }

        // A second launch has already asked the running instance to show itself.
        if (instance is null) { return 0; }
        try
        {
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(app.Dispatcher));
            var crashLog = new AppLog(state, "unhandled");
            var noteLog = new AppLog(state, "notefile");
            NoteFile.Problem = message => noteLog.Error(message);
            app.DispatcherUnhandledException += (_, e) =>
            {
                crashLog.Error($"Unhandled UI exception: {e.Exception}");
                // Corrupted-state failures must not be swallowed.
                e.Handled = e.Exception is not (OutOfMemoryException or AccessViolationException or InsufficientExecutionStackException);
            };
            TaskScheduler.UnobservedTaskException += (_, e) =>
            {
                crashLog.Error($"Unobserved task exception: {e.Exception}");
                e.SetObserved();
            };
            using var theme = new ThemeManager(app.Resources);
            controller = new AppController(app, state, UpdateBootstrap.IsFirstRun);
            app.Dispatcher.InvokeAsync(async () =>
            {
                try { await controller.StartAsync(); }
                catch (Exception error)
                {
                    new AppLog(state, "startup").Error($"Startup failed ({error.GetType().Name}): {error}");
                    app.Shutdown(1);
                }
            });
            app.Run();
            controller.Dispose();
            return 0;
        }
        finally
        {
            instance.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
    }

    private static void AttachConsoleIfNeeded()
    {
        // A WinExe may start without stdout; keep inherited pipes when present.
        var output = GetStdHandle(-11);
        if (output == 0 || output == -1)
        {
            AttachConsole(uint.MaxValue);
        }
    }

    [DllImport("kernel32.dll")]
    private static extern nint GetStdHandle(int kind);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(uint processId);
}
