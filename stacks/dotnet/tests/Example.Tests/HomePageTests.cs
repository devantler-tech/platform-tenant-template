using System.Net;
using Microsoft.AspNetCore.Mvc.Testing;

namespace Example.Tests;

/// <summary>
/// Tests for the page the application serves at <c>/</c>.
/// </summary>
/// <remarks>
/// Joins the shared <c>"FeatureFlags"</c> collection: the app registers OpenFeature's
/// process-wide provider at startup, so flag-exercising test classes must not run in parallel.
/// </remarks>
[Collection("FeatureFlags")]
public class HomePageTests
{
  /// <summary>
  /// Verifies <see cref="HomePage.Render(string)"/> HTML-encodes the message it is given.
  /// </summary>
  [Fact]
  public void Render_MarkupInMessage_IsEncoded()
  {
    // Act
    string page = HomePage.Render("<b>hi</b>");

    // Assert
    Assert.Contains("&lt;b&gt;hi&lt;/b&gt;", page, StringComparison.Ordinal);
  }

  /// <summary>
  /// Verifies the hosted application answers <c>GET /</c>, which the platform's probes call,
  /// with the default-off branch of the example flag.
  /// </summary>
  [Fact]
  public async Task Get_Root_ServesPlaceholderPage()
  {
    // Arrange
    await using var factory = new WebApplicationFactory<Program>();
    using var client = factory.CreateClient();

    // Act
    using var response = await client.GetAsync(
      new Uri("/", UriKind.Relative),
      TestContext.Current.CancellationToken);
    string body = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);

    // Assert
    Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    Assert.Contains("The example feature is off.", body, StringComparison.Ordinal);
  }
}
