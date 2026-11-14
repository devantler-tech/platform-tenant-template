using System.Net;

namespace Example;

/// <summary>
/// Renders the placeholder page the application serves at <c>/</c>. Replace it with your
/// own endpoints.
/// </summary>
static class HomePage
{
  /// <summary>
  /// Renders the placeholder page with <paramref name="message"/> HTML-encoded into it.
  /// </summary>
  /// <param name="message">The text to show below the heading.</param>
  /// <returns>The page as an HTML document.</returns>
  public static string Render(string message) =>
    "<!doctype html><title>app</title><h1>Replace this placeholder with your app.</h1><p>"
    + WebUtility.HtmlEncode(message)
    + "</p>\n";
}
