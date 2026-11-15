using OpenFeature;
using OpenFeature.Providers.Memory;

namespace Example.Tests;

/// <summary>
/// Tests for <see cref="FeatureFlags"/>.
/// </summary>
/// <remarks>
/// Joins the shared <c>"FeatureFlags"</c> xUnit collection.
/// <see cref="FeatureFlags.CreateClientAsync(FeatureProvider)"/> re-registers the
/// process-wide <c>Api.Instance</c> provider, and xUnit runs different test classes in
/// parallel by default — so give every flag-exercising test class the same
/// <c>[Collection("FeatureFlags")]</c> attribute and xUnit runs them sequentially,
/// keeping their provider registrations from interleaving.
/// </remarks>
[Collection("FeatureFlags")]
public class FeatureFlagsTests
{
  /// <summary>
  /// Verifies <see cref="FeatureFlags.DescribeAsync(IFeatureClient)"/> takes the OFF
  /// branch when the example flag is registered default-off (the scaffold default).
  /// </summary>
  [Fact]
  public async Task DescribeAsync_FlagDefaultOff_ReturnsOffMessage()
  {
    // Arrange
    var client = await FeatureFlags.CreateClientAsync(FeatureFlags.CreateInMemoryProvider());

    // Act
    string result = await FeatureFlags.DescribeAsync(client);

    // Assert
    Assert.Contains("is off", result, StringComparison.Ordinal);
  }

  /// <summary>
  /// Verifies <see cref="FeatureFlags.DescribeAsync(IFeatureClient)"/> takes the ON
  /// branch when the example flag resolves on.
  /// </summary>
  [Fact]
  public async Task DescribeAsync_FlagOn_ReturnsOnMessage()
  {
    // Arrange
    var client = await FeatureFlags.CreateClientAsync(BuildExampleProvider(enabled: true));

    // Act
    string result = await FeatureFlags.DescribeAsync(client);

    // Assert
    Assert.Contains("is on", result, StringComparison.Ordinal);
  }

  /// <summary>
  /// Verifies an unset flag falls back to the OFF default, so a missing flag definition
  /// never silently turns a feature on.
  /// </summary>
  [Fact]
  public async Task DescribeAsync_FlagUnset_DefaultsToOff()
  {
    // Arrange
    var provider = new InMemoryProvider(new Dictionary<string, Flag>(StringComparer.Ordinal));
    var client = await FeatureFlags.CreateClientAsync(provider);

    // Act
    string result = await FeatureFlags.DescribeAsync(client);

    // Assert
    Assert.Contains("is off", result, StringComparison.Ordinal);
  }

  /// <summary>
  /// Builds an in-memory provider that resolves <see cref="FeatureFlags.ExampleFeature"/>
  /// to <paramref name="enabled"/>, so both flag states can be exercised.
  /// </summary>
  /// <param name="enabled">Whether the example flag should resolve on.</param>
  /// <returns>An in-memory provider resolving the example flag to <paramref name="enabled"/>.</returns>
  static InMemoryProvider BuildExampleProvider(bool enabled)
  {
    string variant = enabled ? FeatureFlags.EnabledVariant : FeatureFlags.DisabledVariant;
    return new InMemoryProvider(new Dictionary<string, Flag>(StringComparer.Ordinal)
    {
      [FeatureFlags.ExampleFeature] = new Flag<bool>(
        new Dictionary<string, bool>(StringComparer.Ordinal)
        {
          [FeatureFlags.EnabledVariant] = true,
          [FeatureFlags.DisabledVariant] = false,
        },
        variant),
    });
  }
}
