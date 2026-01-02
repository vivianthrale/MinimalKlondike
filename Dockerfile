# Build MinimalKlondike solver with .NET 7.0
FROM mcr.microsoft.com/dotnet/sdk:7.0 AS solver-build
WORKDIR /src
RUN git clone https://github.com/ShootMe/MinimalKlondike.git .
RUN dotnet publish Klondike.csproj -c Release -o /solver
# Build the API wrapper with .NET 8.0
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS api-build
WORKDIR /src
# Create project file
RUN echo '<Project Sdk="Microsoft.NET.Sdk.Web"><PropertyGroup><TargetFramework>net8.0</TargetFramework><Nullable>enable</Nullable><ImplicitUsings>enable</ImplicitUsings></PropertyGroup></Project>' > SolverApi.csproj
# Create Program.cs using printf to avoid instruction parsing issues
RUN printf '%s\n' \
'using System.Diagnostics;' \
'using Microsoft.AspNetCore.Mvc;' \
'' \
'var builder = WebApplication.CreateBuilder(args);' \
'var app = builder.Build();' \
'' \
'app.MapPost("/solve", async ([FromBody] SolverRequest request) =>' \
'{' \
'    try' \
'    {' \
'        var psi = new ProcessStartInfo' \
'        {' \
'            FileName = "/app/solver/Klondike",' \
'            Arguments = request.Deck,' \
'            RedirectStandardOutput = true,' \
'            RedirectStandardError = true,' \
'            UseShellExecute = false,' \
'            CreateNoWindow = true' \
'        };' \
'' \
'        using var process = Process.Start(psi);' \
'        if (process == null)' \
'            return Results.Json(new { success = false, fullySolved = false, error = "Failed to start solver" });' \
'' \
'        var output = await process.StandardOutput.ReadToEndAsync();' \
'        var error = await process.StandardError.ReadToEndAsync();' \
'' \
'        var cts = new CancellationTokenSource(TimeSpan.FromMinutes(2));' \
'        await process.WaitForExitAsync(cts.Token);' \
'' \
'        var movesLine = output.Split(new char[] { (char)10 })' \
'            .FirstOrDefault(l => l.StartsWith("Moves:"));' \
'' \
'        var moves = movesLine != null' \
'            ? movesLine.Replace("Moves:", "").Trim().Split(new char[] { (char)32 }, StringSplitOptions.RemoveEmptyEntries)' \
'            : Array.Empty<string>();' \
'' \
'        bool fullySolved = !output.Contains("Unsolvable") && !output.Contains("No solution") && moves.Length > 0;' \
'' \
'        return Results.Json(new {' \
'            success = moves.Length > 0,' \
'            fullySolved = fullySolved,' \
'            moves = moves,' \
'            moveCount = moves.Length,' \
'            rawOutput = output,' \
'            error = error' \
'        });' \
'    }' \
'    catch (OperationCanceledException)' \
'    {' \
'        return Results.Json(new { success = false, fullySolved = false, error = "Solver timed out" });' \
'    }' \
'    catch (Exception ex)' \
'    {' \
'        return Results.Json(new { success = false, fullySolved = false, error = ex.Message });' \
'    }' \
'});' \
'' \
'app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));' \
'app.MapGet("/", () => Results.Ok(new { service = "MinimalKlondike Solver API" }));' \
'' \
'app.Run();' \
'' \
'public record SolveRequest(string Deck);' > Program.cs
RUN dotnet restore
RUN dotnet publish -c Release -o /api
# Final runtime image - needs BOTH .NET 7.0 and 8.0 runtimes
FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
# Install .NET 7.0 runtime for the solver
RUN apt-get update && apt-get install -y wget && \
    wget https://dot.net/v1/dotnet-install.sh && \
    chmod +x dotnet-install.sh && \
    ./dotnet-install.sh --runtime dotnet --channel 7.0 --install-dir /usr/share/dotnet && \
    rm dotnet-install.sh && \
    apt-get remove -y wget && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
COPY --from=solver-build /solver ./solver
COPY --from=api-build /api .
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "SolverApi.dll"]
