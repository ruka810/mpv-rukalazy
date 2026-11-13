using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Pipes;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

internal static class Program
{
    private const string NativeHostName = "com.mpv_lazy.cookie_bridge";
    private const string BridgeProtocolVersion = "2";
    private const string PipeName = "mpv-lazy-chrome-cookie-bridge-v2";
    private const int WebBridgePort = 49814;
    private const string ExtensionOrigin = "chrome-extension://gikjlcfdnjgmdbdnefmknkpndmkfdlhf";
    private static readonly string CookieExportPath = Path.Combine(
        WorkspaceRoot(), "portable_config", "_cache", "cookies", "yt+bilibili.txt");
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--serve") return await RunWebBridgeServerAsync();
            if (args.Length == 0) return await RunNativeHostAsync();
            if (args.Length >= 2 && args[0] == "--get") return await RunGetAsync(args[1]);
            if (args.Length >= 2 && args[0] == "--bilibili-fetch") return await RunBilibiliFetchAsync(args);
            if (args.Length == 2 && args[0] == "--session-open") return await RunSessionAsync("session-open", args[1]);
            if (args.Length == 2 && args[0] == "--session-close") return await RunSessionAsync("session-close", args[1]);
            if (args.Length == 1 && args[0] == "--clear") return await RunClearAsync();
            if (args.Length == 1 && args[0] == "--status") return await RunStatusAsync();
            if (args.Length == 1 && args[0] == "--warm") return await RunWarmAsync();
            return await RunYtDlpFacadeAsync(StripCookieFileArguments(args));
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("[mpv-cookie-bridge] " + SafeError(error));
            return 1;
        }
    }

    private static async Task<int> RunNativeHostAsync()
    {
        using var input = Console.OpenStandardInput();
        using var output = Console.OpenStandardOutput();
        using var stop = new CancellationTokenSource();
        try
        {
            while (true)
            {
                using var message = await ReadNativeMessageAsync(input, stop.Token);
                if (message is null) break;
                await HandleNativeHostMessageAsync(message, output, stop.Token);
            }
        }
        catch (OperationCanceledException) { }
        return 0;
    }

    private static async Task HandleNativeHostMessageAsync(JsonDocument message, Stream output, CancellationToken cancellation)
    {
        var type = message.RootElement.TryGetProperty("type", out var typeElement) ? typeElement.GetString() : null;
        if (type == "ping")
        {
            await WriteNativeMessageAsync(output, new { type = "pong", protocol = BridgeProtocolVersion }, cancellation);
            return;
        }

        try
        {
            await EnsureWebBridgeServerAsync();
            await WriteNativeMessageAsync(output, new
            {
                type = "bridge-ready",
                host = NativeHostName,
                protocol = BridgeProtocolVersion,
                health = $"http://127.0.0.1:{WebBridgePort}/health",
            }, cancellation);
        }
        catch (Exception error)
        {
            Diagnostic("native-bootstrap: " + error.GetType().Name + " " + error.Message);
            await WriteNativeMessageAsync(output, new { type = "bridge-error", protocol = BridgeProtocolVersion, error = "Bridge service unavailable" }, cancellation);
        }
    }

    private static async Task WriteNativeMessageAsync(Stream output, object message, CancellationToken cancellation)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(message, Json);
        await output.WriteAsync(BitConverter.GetBytes(body.Length), cancellation);
        await output.WriteAsync(body, cancellation);
        await output.FlushAsync(cancellation);
    }

    private static void Diagnostic(string message)
    {
        try
        {
            File.AppendAllText(Path.Combine(Path.GetTempPath(), "mpv-cookie-bridge-diagnostics.log"),
                DateTime.UtcNow.ToString("O") + " " + message + Environment.NewLine);
        }
        catch { }
    }

    private static async Task<int> RunGetAsync(string site)
    {
        var result = await CallServiceAsync(new { op = "get", site });
        await Console.Out.WriteLineAsync(result);
        return JsonDocument.Parse(result).RootElement.TryGetProperty("ok", out var ok) && ok.GetBoolean() ? 0 : 2;
    }

    private static async Task<int> RunStatusAsync()
    {
        var result = await CallServiceAsync(new { op = "status" });
        await Console.Out.WriteLineAsync(result);
        return 0;
    }

    private static async Task<int> RunWarmAsync()
    {
        // Starts the local service at mpv startup.  If Chrome is already
        // connected the response is immediate; otherwise its next connection
        // automatically snapshots both supported sites into process memory.
        var result = await CallServiceAsync(new { op = "warm" });
        await Console.Out.WriteLineAsync(result);
        return 0;
    }

    private static async Task<int> RunClearAsync()
    {
        var result = await CallServiceAsync(new { op = "clear" });
        await Console.Out.WriteLineAsync(result);
        return JsonDocument.Parse(result).RootElement.TryGetProperty("ok", out var ok) && ok.GetBoolean() ? 0 : 2;
    }

    private static async Task<int> RunSessionAsync(string operation, string sessionId)
    {
        if (string.IsNullOrWhiteSpace(sessionId)) throw new InvalidOperationException("Missing mpv session identifier");
        var result = await CallServiceAsync(new { op = operation, sessionId });
        await Console.Out.WriteLineAsync(result);
        return JsonDocument.Parse(result).RootElement.TryGetProperty("ok", out var ok) && ok.GetBoolean() ? 0 : 2;
    }

    private static async Task<int> RunBilibiliFetchAsync(IReadOnlyList<string> args)
    {
        var url = args[1];
        string? proxy = null;
        string? output = null;
        for (var index = 2; index < args.Count; index++)
        {
            if (args[index] == "--proxy" && index + 1 < args.Count) proxy = args[++index];
            else if (args[index] == "--output" && index + 1 < args.Count) output = args[++index];
            else throw new InvalidOperationException("Invalid Bilibili fetch argument");
        }
        var result = await CallServiceAsync(new { op = "fetch-bilibili", url, proxy });
        using var response = JsonDocument.Parse(result);
        if (!response.RootElement.TryGetProperty("ok", out var ok) || !ok.GetBoolean())
            throw new InvalidOperationException(response.RootElement.TryGetProperty("error", out var error) ? error.GetString() : "Bilibili fetch failed");
        var content = response.RootElement.GetProperty("content").GetString() ?? string.Empty;
        var bytes = Convert.FromBase64String(content);
        if (string.IsNullOrWhiteSpace(output))
        {
            await Console.OpenStandardOutput().WriteAsync(bytes);
            return 0;
        }
        await File.WriteAllBytesAsync(output, bytes);
        return 0;
    }

    private static async Task<string> CallServiceAsync(object request)
    {
        await EnsureWebBridgeServerAsync();
        using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        // A dormant MV3 worker can need up to the next Chrome alarm tick to
        // reconnect.  The extension normally stays alive through WebSocket
        // heartbeats, but do not silently fall back to anonymous yt-dlp during
        // that recovery window.
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(40));
        await pipe.ConnectAsync(timeout.Token);
        using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true) { AutoFlush = true, NewLine = "\n" };
        using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 1024, true);
        await writer.WriteLineAsync(JsonSerializer.Serialize(request, Json));
        return await reader.ReadLineAsync(timeout.Token) ?? "{\"ok\":false,\"error\":\"Chrome Cookie Bridge returned no data\"}";
    }

    private static async Task EnsureWebBridgeServerAsync()
    {
        using (var probe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
        using (var shortTimeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(250)))
        {
            try { await probe.ConnectAsync(shortTimeout.Token); return; } catch { }
        }
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Cannot locate bridge executable");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("--serve");
        _ = Process.Start(start);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
        while (!timeout.IsCancellationRequested)
        {
            using var probe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            try { await probe.ConnectAsync(timeout.Token); return; }
            catch (OperationCanceledException) { break; }
            catch { await Task.Delay(80, timeout.Token); }
        }
        throw new InvalidOperationException("Chrome Cookie Bridge service did not start");
    }

    private static async Task<int> RunWebBridgeServerAsync()
    {
        using var instanceGuard = new Mutex(false, @"Local\mpv-lazy-chrome-cookie-bridge-v2", out var isFirstInstance);
        if (!isFirstInstance) return 0;
        using var cancellation = new CancellationTokenSource();
        var session = new WebCookieSession(cancellation.Token);
        var pipeTask = ServeWebPipeAsync(session, cancellation.Token);
        using var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{WebBridgePort}/");
        listener.Start();
        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                var context = await listener.GetContextAsync();
                _ = Task.Run(async () =>
                {
                    try
                    {
                        if (context.Request.HttpMethod == "GET" && context.Request.Url?.AbsolutePath == "/health")
                        {
                            await WriteHealthResponseAsync(context, cancellation.Token);
                            return;
                        }
                        if (!context.Request.IsWebSocketRequest || context.Request.Url?.AbsolutePath != "/bridge" ||
                            !string.Equals(context.Request.Headers["Origin"], ExtensionOrigin, StringComparison.Ordinal))
                        {
                            context.Response.StatusCode = 403;
                            context.Response.Close();
                            return;
                        }
                        var socket = (await context.AcceptWebSocketAsync(null)).WebSocket;
                        await session.RunSocketAsync(socket, cancellation.Token);
                    }
                    catch { try { context.Response.Abort(); } catch { } }
                }, CancellationToken.None);
            }
        }
        finally
        {
            cancellation.Cancel();
            session.FailPending("Chrome Cookie Bridge disconnected");
            try { await pipeTask; } catch (OperationCanceledException) { }
        }
        return 0;
    }

    private static async Task WriteHealthResponseAsync(HttpListenerContext context, CancellationToken cancellation)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(new { ok = true, ready = true, protocol = BridgeProtocolVersion }, Json);
        context.Response.StatusCode = (int)HttpStatusCode.OK;
        context.Response.ContentType = "application/json";
        context.Response.ContentLength64 = payload.Length;
        context.Response.Headers["Access-Control-Allow-Origin"] = ExtensionOrigin;
        await context.Response.OutputStream.WriteAsync(payload, cancellation);
        context.Response.Close();
    }

    private static async Task ServeWebPipeAsync(WebCookieSession session, CancellationToken cancellation)
    {
        while (!cancellation.IsCancellationRequested)
        {
            var pipe = new NamedPipeServerStream(PipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
                PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            try
            {
                await pipe.WaitForConnectionAsync(cancellation);
                _ = Task.Run(async () => { using (pipe) await HandleWebPipeClientAsync(pipe, session, cancellation); }, CancellationToken.None);
            }
            catch { pipe.Dispose(); if (cancellation.IsCancellationRequested) break; }
        }
    }

    private static async Task HandleWebPipeClientAsync(NamedPipeServerStream pipe, WebCookieSession session, CancellationToken cancellation)
    {
        using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 1024, true);
        using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true) { AutoFlush = true, NewLine = "\n" };
        try
        {
            var line = await reader.ReadLineAsync(cancellation);
            if (string.IsNullOrWhiteSpace(line)) return;
            using var request = JsonDocument.Parse(line);
            var operation = request.RootElement.TryGetProperty("op", out var op) ? op.GetString() : null;
            if (operation == "status")
            {
                await writer.WriteLineAsync(JsonSerializer.Serialize(new
                {
                    ok = true,
                    connected = session.Connected,
                    cached = session.HasCachedCookies,
                    bilibiliCached = session.HasCachedCookiesFor("bilibili"),
                    youtubeCached = session.HasCachedCookiesFor("youtube"),
                    sessions = session.SessionCount,
                    protocol = BridgeProtocolVersion,
                }, Json));
                return;
            }
            if (operation == "warm")
            {
                session.RequestWarmup();
                await writer.WriteLineAsync(JsonSerializer.Serialize(new
                {
                    ok = true,
                    connected = session.Connected,
                    cached = session.HasCachedCookies,
                    bilibiliCached = session.HasCachedCookiesFor("bilibili"),
                    youtubeCached = session.HasCachedCookiesFor("youtube"),
                    protocol = BridgeProtocolVersion,
                }, Json));
                return;
            }
            if (operation == "clear")
            {
                session.ClearCache();
                await writer.WriteLineAsync(JsonSerializer.Serialize(new { ok = true, cleared = true }, Json));
                return;
            }
            if (operation is "session-open" or "session-close")
            {
                if (!request.RootElement.TryGetProperty("sessionId", out var sessionIdElement))
                    throw new InvalidOperationException("Missing mpv session identifier");
                var sessionId = sessionIdElement.GetString();
                if (string.IsNullOrWhiteSpace(sessionId)) throw new InvalidOperationException("Missing mpv session identifier");
                if (operation == "session-open") session.OpenSession(sessionId);
                else session.CloseSession(sessionId);
                await writer.WriteLineAsync(JsonSerializer.Serialize(new { ok = true, sessions = session.SessionCount }, Json));
                return;
            }
            if (operation == "fetch-bilibili")
            {
                if (!request.RootElement.TryGetProperty("url", out var urlElement)) throw new InvalidOperationException("Missing Bilibili fetch URL");
                var proxy = request.RootElement.TryGetProperty("proxy", out var proxyElement) ? proxyElement.GetString() : null;
                var content = await session.FetchBilibiliAsync(urlElement.GetString() ?? string.Empty, proxy, cancellation);
                await writer.WriteLineAsync(JsonSerializer.Serialize(new { ok = true, content = Convert.ToBase64String(content) }, Json));
                return;
            }
            if (operation != "get" || !request.RootElement.TryGetProperty("site", out var siteElement)) throw new InvalidOperationException("Invalid local bridge request");
            var cookies = await session.GetCookiesAsync(siteElement.GetString() ?? string.Empty, cancellation);
            await writer.WriteLineAsync(JsonSerializer.Serialize(new { ok = true, cookies }, Json));
        }
        catch (Exception error)
        {
            await writer.WriteLineAsync(JsonSerializer.Serialize(new { ok = false, error = SafeError(error) }, Json));
        }
    }

    private static async Task<int> RunYtDlpFacadeAsync(IReadOnlyList<string> arguments)
    {
        var site = SiteForArguments(arguments);
        if (site is null) return await RelayProcessAsync(OriginalYtDlpPath(), arguments, null);
        string cookieResponse;
        try
        {
            var status = await CallServiceAsync(new { op = "status" });
            if (!BridgeCanSupplyCookies(status, site))
                return await RunWithExportedCookiesAsync(site, arguments, "no in-memory Cookie cache");

            cookieResponse = await CallServiceAsync(new { op = "get", site });
            using var response = JsonDocument.Parse(cookieResponse);
            if (!response.RootElement.TryGetProperty("ok", out var ok) || !ok.GetBoolean())
            {
                var reason = response.RootElement.TryGetProperty("error", out var error) ? error.GetString() : null;
                throw new InvalidOperationException(reason ?? "Cookie Bridge unavailable");
            }
        }
        catch (Exception error)
        {
            return await RunWithExportedCookiesAsync(site, arguments, SafeError(error));
        }

        return await RunWithMemoryCookiesAsync(arguments, cookieResponse);
    }

    private static bool BridgeCanSupplyCookies(string status, string site)
    {
        using var response = JsonDocument.Parse(status);
        var root = response.RootElement;
        if (!root.TryGetProperty("ok", out var ok) || !ok.GetBoolean()) return false;
        if (root.TryGetProperty("connected", out var connected) && connected.GetBoolean()) return true;
        var cacheKey = site + "Cached";
        return root.TryGetProperty(cacheKey, out var cached) && cached.GetBoolean();
    }

    private static async Task<int> RunWithMemoryCookiesAsync(IReadOnlyList<string> arguments, string cookieResponse)
    {
        var wrapper = CookieWrapperPath();
        if (!File.Exists(wrapper)) throw new FileNotFoundException("yt-dlp Cookie wrapper is unavailable", wrapper);
        var pythonArgs = new List<string> { wrapper, "--cookie-json-stdin" };
        pythonArgs.AddRange(arguments);
        return await RelayProcessAsync(PythonPath(), pythonArgs, cookieResponse);
    }

    private static async Task<int> RunWithExportedCookiesAsync(string site, IReadOnlyList<string> arguments, string reason)
    {
        if (!HasExportedCookies())
        {
            Console.Error.WriteLine($"ERROR: [mpv-cookie-bridge] {site} Cookie Bridge unavailable and no exported Cookie file is available: {reason}");
            return 2;
        }

        var wrapper = CookieWrapperPath();
        if (!File.Exists(wrapper)) throw new FileNotFoundException("yt-dlp Cookie wrapper is unavailable", wrapper);
        Console.Error.WriteLine($"INFO: [mpv-cookie-bridge] {site} is using the exported Cookie file");
        var pythonArgs = new List<string> { wrapper, "--cookie-file", CookieExportPath };
        pythonArgs.AddRange(arguments);
        return await RelayProcessAsync(PythonPath(), pythonArgs, null);
    }

    private static bool HasExportedCookies()
    {
        try { return new FileInfo(CookieExportPath) is { Exists: true, Length: > 64 }; }
        catch { return false; }
    }

    private static string CookieWrapperPath() => Path.Combine(
        WorkspaceRoot(), "portable_config", "tools", "chrome_cookie_bridge", "ytdlp_memory_wrapper.py");
    private static async Task<int> RelayProcessAsync(string executable, IReadOnlyList<string> arguments, string? input)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = input is not null, CreateNoWindow = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start helper process");
        var stdout = process.StandardOutput.BaseStream.CopyToAsync(Console.OpenStandardOutput());
        var stderr = process.StandardError.BaseStream.CopyToAsync(Console.OpenStandardError());
        if (input is not null)
        {
            await process.StandardInput.WriteAsync(input);
            await process.StandardInput.FlushAsync();
            process.StandardInput.Close();
        }
        await Task.WhenAll(stdout, stderr, process.WaitForExitAsync());
        return process.ExitCode;
    }

    private static string? SiteForArguments(IReadOnlyList<string> args)
    {
        foreach (var value in args.Reverse())
        {
            if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)) continue;
            var host = uri.Host.ToLowerInvariant();
            if (host == "bilibili.com" || host.EndsWith(".bilibili.com")) return "bilibili";
            if (host == "youtube.com" || host.EndsWith(".youtube.com") || host == "youtu.be") return "youtube";
        }
        return null;
    }

    private static IReadOnlyList<string> StripCookieFileArguments(IReadOnlyList<string> source)
    {
        var output = new List<string>();
        for (var index = 0; index < source.Count; index++)
        {
            var value = source[index];
            if (value is "--cookies" or "--cookies-from-browser") { index++; continue; }
            if (value.StartsWith("--cookies=", StringComparison.Ordinal) || value.StartsWith("--cookies-from-browser=", StringComparison.Ordinal)) continue;
            output.Add(value);
        }
        return output;
    }

    private static string WorkspaceRoot()
    {
        foreach (var start in new[] { AppContext.BaseDirectory, Directory.GetCurrentDirectory() })
        {
            for (var directory = new DirectoryInfo(start); directory is not null; directory = directory.Parent)
            {
                if (File.Exists(Path.Combine(directory.FullName, "yt-dlp.exe"))) return directory.FullName;
            }
        }
        return Directory.GetCurrentDirectory();
    }

    private static string OriginalYtDlpPath() => Path.Combine(WorkspaceRoot(), "yt-dlp.exe");
    private static string PythonPath()
    {
        var configured = Environment.GetEnvironmentVariable("MPV_LAZY_PYTHON");
        if (!string.IsNullOrWhiteSpace(configured) && File.Exists(configured)) return configured;
        var workspacePython = Path.Combine(WorkspaceRoot(), "python.exe");
        if (File.Exists(workspacePython)) return workspacePython;
        return "python.exe";
    }

    private static async Task<JsonDocument?> ReadNativeMessageAsync(Stream input, CancellationToken cancellation)
    {
        var header = new byte[4];
        if (await ReadExactlyAsync(input, header, cancellation) != 4) return null;
        var length = BitConverter.ToInt32(header, 0);
        if (length <= 0 || length > 2 * 1024 * 1024) throw new InvalidOperationException("Invalid native message length");
        var payload = new byte[length];
        if (await ReadExactlyAsync(input, payload, cancellation) != length) return null;
        return JsonDocument.Parse(payload);
    }

    private static async Task<int> ReadExactlyAsync(Stream stream, byte[] buffer, CancellationToken cancellation)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var amount = await stream.ReadAsync(buffer.AsMemory(offset), cancellation);
            if (amount == 0) break;
            offset += amount;
        }
        return offset;
    }

    private static string SafeError(Exception error) => error.Message.Replace('\r', ' ').Replace('\n', ' ');

    private sealed class WebCookieSession(CancellationToken shutdown)
    {
        private readonly SemaphoreSlim _sendLock = new(1, 1);
        private readonly SemaphoreSlim _exportLock = new(1, 1);
        private readonly ConcurrentDictionary<string, TaskCompletionSource<JsonElement>> _pending = new();
        private readonly ConcurrentDictionary<string, JsonElement> _cookieCache = new();
        private readonly ConcurrentDictionary<string, byte> _sessions = new();
        private readonly object _socketLock = new();
        private WebSocket? _socket;
        private TaskCompletionSource<bool> _connectionReady = NewConnectionSignal();

        private static TaskCompletionSource<bool> NewConnectionSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

        public bool Connected
        {
            get
            {
                lock (_socketLock) return _socket?.State == WebSocketState.Open;
            }
        }

        public bool HasCachedCookies => _cookieCache.Count > 0;

        public bool HasCachedCookiesFor(string site) => _cookieCache.ContainsKey(site);

        public int SessionCount => _sessions.Count;

        public void OpenSession(string sessionId) => _sessions[sessionId] = 0;

        public void CloseSession(string sessionId)
        {
            _sessions.TryRemove(sessionId, out _);
            // The service is shared by all mpv windows.  Clearing unconditionally
            // on any one window's shutdown used to make a still-running player
            // lose its Cookie cache.  Only the last registered session releases
            // the memory jars.
            if (_sessions.IsEmpty) ClearCache();
        }

        public async Task RunSocketAsync(WebSocket socket, CancellationToken cancellation)
        {
            WebSocket? previous;
            lock (_socketLock)
            {
                previous = _socket;
                _socket = socket;
                _connectionReady.TrySetResult(true);
            }
            if (previous is not null && previous != socket)
            {
                try { await previous.CloseAsync(WebSocketCloseStatus.NormalClosure, "Replaced", CancellationToken.None); } catch { }
                previous.Dispose();
            }

            // Snapshot both sites immediately.  The cache must exist before a
            // first video/playlist/danmaku operation so that closing Chrome
            // afterwards behaves like a per-session cookies.txt file.
            RequestWarmup();

            try
            {
                var buffer = new byte[256 * 1024];
                while (!cancellation.IsCancellationRequested && socket.State == WebSocketState.Open)
                {
                    using var data = new MemoryStream();
                    WebSocketReceiveResult result;
                    do
                    {
                        result = await socket.ReceiveAsync(buffer, cancellation);
                        if (result.MessageType == WebSocketMessageType.Close)
                        {
                            try { await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Closing", CancellationToken.None); } catch { }
                            return;
                        }
                        data.Write(buffer, 0, result.Count);
                        if (data.Length > 2 * 1024 * 1024) throw new InvalidOperationException("Bridge message is too large");
                    }
                    while (!result.EndOfMessage);
                    if (result.MessageType != WebSocketMessageType.Text) continue;
                    using var document = JsonDocument.Parse(data.ToArray());
                    HandleBrowserMessage(document);
                }
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            catch { }
            finally
            {
                var lostActiveSocket = false;
                lock (_socketLock)
                {
                    if (_socket == socket)
                    {
                        _socket = null;
                        _connectionReady = NewConnectionSignal();
                        lostActiveSocket = true;
                    }
                }
                if (lostActiveSocket)
                {
                    FailPending("Chrome Cookie Bridge disconnected");
                    if (_sessions.IsEmpty) ClearCache();
                }
                socket.Dispose();
            }
        }

        public async Task<JsonElement> GetCookiesAsync(string site, CancellationToken cancellation)
        {
            if (site is not ("bilibili" or "youtube")) throw new InvalidOperationException("Unsupported cookie site");
            if (!Connected)
            {
                if (_cookieCache.TryGetValue(site, out var cached)) return cached.Clone();
                Task connectionTask;
                lock (_socketLock) connectionTask = _connectionReady.Task;
                await connectionTask.WaitAsync(TimeSpan.FromSeconds(35), cancellation);
            }
            if (!Connected)
            {
                if (_cookieCache.TryGetValue(site, out var cached)) return cached.Clone();
                throw new InvalidOperationException("Chrome extension is not connected and no in-memory Cookie cache is available");
            }
            var requestId = Guid.NewGuid().ToString("N");
            var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!_pending.TryAdd(requestId, completion)) throw new InvalidOperationException("Could not create cookie request");
            try
            {
                await SendAsync(new { type = "get_cookies", requestId, site }, cancellation);
                var cookies = await completion.Task.WaitAsync(TimeSpan.FromSeconds(8), cancellation);
                CacheCookies(site, cookies);
                return cookies;
            }
            finally { _pending.TryRemove(requestId, out _); }
        }

        public void RequestWarmup()
        {
            if (!Connected) return;
            _ = Task.Run(async () =>
            {
                foreach (var site in new[] { "bilibili", "youtube" })
                {
                    try { await GetCookiesAsync(site, shutdown); }
                    catch { /* Keep the other site's cache independent. */ }
                }
            }, CancellationToken.None);
        }

        public async Task<byte[]> FetchBilibiliAsync(string value, string? proxy, CancellationToken cancellation)
        {
            if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
                || uri.Scheme is not ("http" or "https")
                || !(uri.Host.Equals("bilibili.com", StringComparison.OrdinalIgnoreCase)
                    || uri.Host.EndsWith(".bilibili.com", StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("Only Bilibili HTTP(S) URLs may be fetched");

            using var handler = new HttpClientHandler
            {
                AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli,
                CookieContainer = new CookieContainer(),
                UseProxy = !string.IsNullOrWhiteSpace(proxy),
            };
            if (!string.IsNullOrWhiteSpace(proxy)) handler.Proxy = new WebProxy(proxy);

            // Public Bilibili metadata and XML remain usable without Chrome.
            // When this session has a cached/connected browser jar, add it but
            // never wait for a closed browser to satisfy a public request.
            var cookies = await GetBilibiliCookiesIfAvailableAsync(cancellation);
            if (cookies is { } cookieList && cookieList.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in cookieList.EnumerateArray())
                {
                    try
                    {
                        if (!item.TryGetProperty("name", out var name) || !item.TryGetProperty("value", out var cookieValue)
                            || !item.TryGetProperty("domain", out var domain)) continue;
                        var cookieName = name.GetString();
                        var valueText = cookieValue.GetString();
                        var domainText = domain.GetString();
                        if (string.IsNullOrWhiteSpace(cookieName) || valueText is null || string.IsNullOrWhiteSpace(domainText)) continue;
                        var path = item.TryGetProperty("path", out var pathElement) ? pathElement.GetString() : "/";
                        handler.CookieContainer.Add(new Cookie(cookieName, valueText, string.IsNullOrWhiteSpace(path) ? "/" : path, domainText));
                    }
                    catch (CookieException) { }
                }
            }

            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            request.Headers.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36");
            request.Headers.Referrer = new Uri("https://www.bilibili.com/");
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
            response.EnsureSuccessStatusCode();
            return await response.Content.ReadAsByteArrayAsync(cancellation);
        }

        private async Task<JsonElement?> GetBilibiliCookiesIfAvailableAsync(CancellationToken cancellation)
        {
            if (_cookieCache.TryGetValue("bilibili", out var cached)) return cached.Clone();
            if (!Connected) return null;
            try { return await GetCookiesAsync("bilibili", cancellation); }
            catch { return null; }
        }

        private void HandleBrowserMessage(JsonDocument document)
        {
            var root = document.RootElement;
            if (!root.TryGetProperty("type", out var type)) return;
            var messageType = type.GetString();
            if (messageType is "hello" or "ping")
            {
                _ = SendAsync(new { type = messageType == "hello" ? "ready" : "pong" }, shutdown);
                return;
            }
            if (messageType == "cookie_snapshot")
            {
                var site = root.TryGetProperty("site", out var snapshotSite) ? snapshotSite.GetString() : null;
                if (site is "bilibili" or "youtube"
                    && root.TryGetProperty("cookies", out var snapshotCookies)
                    && snapshotCookies.ValueKind == JsonValueKind.Array)
                {
                    CacheCookies(site, snapshotCookies);
                }
                return;
            }
            if (messageType != "cookies") return;
            if (!root.TryGetProperty("requestId", out var id) || !root.TryGetProperty("cookies", out var cookies)) return;
            var requestId = id.GetString();
            if (string.IsNullOrWhiteSpace(requestId) || !_pending.TryGetValue(requestId, out var completion)) return;
            if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String)
                completion.TrySetException(new InvalidOperationException(error.GetString() ?? "Chrome did not provide cookies"));
            else
                completion.TrySetResult(cookies.Clone());
        }

        private async Task SendAsync(object message, CancellationToken cancellation)
        {
            WebSocket socket;
            lock (_socketLock) socket = _socket ?? throw new InvalidOperationException("Chrome extension is not connected");
            var bytes = JsonSerializer.SerializeToUtf8Bytes(message, Json);
            await _sendLock.WaitAsync(cancellation);
            try
            {
                if (socket.State != WebSocketState.Open) throw new InvalidOperationException("Chrome extension is not connected");
                await socket.SendAsync(bytes, WebSocketMessageType.Text, true, cancellation);
            }
            finally { _sendLock.Release(); }
        }

        public void FailPending(string reason)
        {
            foreach (var item in _pending) item.Value.TrySetException(new InvalidOperationException(reason));
        }

        public void ClearCache()
        {
            _cookieCache.Clear();
        }

        private void CacheCookies(string site, JsonElement cookies)
        {
            _cookieCache[site] = cookies.Clone();
            _ = Task.Run(ExportCachedCookiesAsync);
        }

        private async Task ExportCachedCookiesAsync()
        {
            await _exportLock.WaitAsync();
            try
            {
                var rows = new HashSet<string>(StringComparer.Ordinal);
                foreach (var site in new[] { "bilibili", "youtube" })
                {
                    if (!_cookieCache.TryGetValue(site, out var cookies) || cookies.ValueKind != JsonValueKind.Array) continue;
                    foreach (var cookie in cookies.EnumerateArray())
                    {
                        var row = NetscapeCookieRow(cookie);
                        if (row is not null) rows.Add(row);
                    }
                }
                if (rows.Count == 0) return;

                var output = new StringBuilder();
                output.AppendLine("# Netscape HTTP Cookie File");
                output.AppendLine("# Exported locally by mpv Chrome Cookie Bridge.");
                output.AppendLine();
                foreach (var row in rows.OrderBy(row => row, StringComparer.Ordinal)) output.AppendLine(row);

                var directory = Path.GetDirectoryName(CookieExportPath);
                if (!string.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
                var temporaryPath = CookieExportPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
                await File.WriteAllTextAsync(temporaryPath, output.ToString(), new UTF8Encoding(false));
                File.Move(temporaryPath, CookieExportPath, true);
            }
            catch (Exception error)
            {
                Diagnostic("cookie-export: " + error.GetType().Name + " " + error.Message);
            }
            finally
            {
                _exportLock.Release();
            }
        }

        private static string? NetscapeCookieRow(JsonElement cookie)
        {
            if (!cookie.TryGetProperty("name", out var nameElement) || nameElement.ValueKind != JsonValueKind.String
                || !cookie.TryGetProperty("value", out var valueElement) || valueElement.ValueKind != JsonValueKind.String
                || !cookie.TryGetProperty("domain", out var domainElement) || domainElement.ValueKind != JsonValueKind.String)
                return null;

            var name = CookieField(nameElement.GetString() ?? string.Empty);
            var value = CookieField(valueElement.GetString() ?? string.Empty);
            var domain = CookieField(domainElement.GetString() ?? string.Empty);
            if (name.Length == 0 || domain.Length == 0) return null;

            var path = cookie.TryGetProperty("path", out var pathElement) && pathElement.ValueKind == JsonValueKind.String
                ? CookieField(pathElement.GetString() ?? "/") : "/";
            if (path.Length == 0) path = "/";
            var secure = cookie.TryGetProperty("secure", out var secureElement) && secureElement.ValueKind == JsonValueKind.True;
            var httpOnly = cookie.TryGetProperty("httpOnly", out var httpOnlyElement) && httpOnlyElement.ValueKind == JsonValueKind.True;
            var expiry = "0";
            if (cookie.TryGetProperty("expirationDate", out var expiryElement)
                && expiryElement.ValueKind == JsonValueKind.Number
                && expiryElement.TryGetDouble(out var expirySeconds)
                && double.IsFinite(expirySeconds) && expirySeconds > 0)
                expiry = Math.Floor(expirySeconds).ToString("0", System.Globalization.CultureInfo.InvariantCulture);

            var exportedDomain = httpOnly ? "#HttpOnly_" + domain : domain;
            var includeSubdomains = domain.StartsWith(".", StringComparison.Ordinal) ? "TRUE" : "FALSE";
            return string.Join("\t", exportedDomain, includeSubdomains, path, secure ? "TRUE" : "FALSE", expiry, name, value);
        }

        private static string CookieField(string value) => value.Replace("\r", string.Empty).Replace("\n", string.Empty).Replace("\t", string.Empty);
    }
}
