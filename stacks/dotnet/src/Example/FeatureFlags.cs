using OpenFeature;
using OpenFeature.Providers.Memory;

namespace Example;

/// <summary>
/// Feature-flag scaffolding for the template. New features land <em>behind a flag,
/// default-off</em>, are tested in both states, and are switched on only after
/// validation (see <c>AGENTS.md</c> § Feature flags). Call sites use the portable,
/// vendor-neutral <see href="https://openfeature.dev/">OpenFeature</see> API, so the
/// backing provider can change without touching them. The scaffold ships OpenFeature's
/// built-in in-memory provider so the example evaluates with no external backend —
/// replace it with a real provider (flagd for GitOps, a hosted service, …) when you
/// adopt the template.
/// </summary>
static class FeatureFlags
{
  /// <summary>
  /// Key of the example feature flag. It is registered <em>default-off</em> and gates
  /// <see cref="DescribeAsync(IFeatureClient)"/>; replace it with your own flags.
  /// </summary>
  public const string ExampleFeature = "example-feature";

  /// <summary>Variant key the in-memory provider resolves to <see langword="true"/> (flag on).</summary>
  public const string EnabledVariant = "on";

  /// <summary>Variant key the in-memory provider resolves to <see langword="false"/> (flag off).</summary>
  public const string DisabledVariant = "off";

  /// <summary>
  /// Builds an OpenFeature in-memory provider seeding <see cref="ExampleFeature"/>
  /// default-off, so the scaffold evaluates flags with no external backend. Swap it for
  /// a real provider (flagd, …) without changing any call site.
  /// </summary>
  /// <returns>An in-memory provider with the example flag registered default-off.</returns>
  public static FeatureProvider CreateInMemoryProvider()
  {
    return new InMemoryProvider(new Dictionary<string, Flag>(StringComparer.Ordinal)
    {
      [ExampleFeature] = new Flag<bool>(
        new Dictionary<string, bool>(StringComparer.Ordinal)
        {
          [EnabledVariant] = true,
          [DisabledVariant] = false,
        },
        DisabledVariant),
    });
  }

  /// <summary>
  /// Registers <paramref name="provider"/> as the OpenFeature provider and returns a
  /// client that call sites evaluate flags against.
  /// </summary>
  /// <param name="provider">The provider to register (e.g. from <see cref="CreateInMemoryProvider"/>).</param>
  /// <returns>An OpenFeature client bound to the registered provider.</returns>
  /// <remarks>
  /// Call this once during application startup: it re-registers OpenFeature's process-wide
  /// default provider, and because clients resolve the <em>current</em> provider dynamically,
  /// a later call silently redirects clients obtained earlier. If you need several independent
  /// registrations, reach for OpenFeature's domain/named-client API instead of repeated calls.
  /// </remarks>
  public static async Task<IFeatureClient> CreateClientAsync(FeatureProvider provider)
  {
    ArgumentNullException.ThrowIfNull(provider);
    await Api.Instance.SetProviderAsync(provider).ConfigureAwait(false);
    return Api.Instance.GetClient();
  }

  /// <summary>
  /// Example of gating behaviour on <see cref="ExampleFeature"/>: returns the enhanced
  /// message when the flag resolves on, and the default message when it is off or unset.
  /// Replace it with your own flag-gated code path.
  /// </summary>
  /// <param name="featureClient">The OpenFeature client to evaluate the flag with.</param>
  /// <returns>The flag-gated message.</returns>
  public static async Task<string> DescribeAsync(IFeatureClient featureClient)
  {
    ArgumentNullException.ThrowIfNull(featureClient);
    bool enabled = await featureClient
      .GetBooleanValueAsync(ExampleFeature, false)
      .ConfigureAwait(false);
    return enabled ? "The example feature is on." : "The example feature is off.";
  }
}
