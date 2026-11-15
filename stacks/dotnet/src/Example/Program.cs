using Example;

var builder = WebApplication.CreateBuilder(args);

// Listen on PORT (default 3000), matching the containerPort and probes in
// deploy/deployment.yaml.
string port = Environment.GetEnvironmentVariable("PORT") ?? "3000";
builder.WebHost.UseUrls($"http://+:{port}");

var app = builder.Build();

var featureClient = await FeatureFlags.CreateClientAsync(FeatureFlags.CreateInMemoryProvider());

// The platform's liveness and readiness probes call GET /. Keep it answering, or
// move the probes with it.
app.MapGet("/", async () => Results.Content(
  HomePage.Render(await FeatureFlags.DescribeAsync(featureClient)),
  "text/html; charset=utf-8"));

await app.RunAsync();
