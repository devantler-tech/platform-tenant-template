// Package featureflag is a minimal, replaceable feature-flag scaffold.
//
// It wires the portable OpenFeature Go SDK (github.com/open-feature/go-sdk) as
// the runtime flag API so every new feature can be landed behind a flag,
// default-off, and flipped on only after validation — the feature-flag-first
// delivery convention (see AGENTS.md).
//
// The template ships the in-memory provider (openfeature/memprovider) so the
// example flag evaluates and its tests pass with no running backend. In a real
// service, swap the provider for flagd
// (github.com/open-feature/go-sdk-contrib/providers/flagd) to read FeatureFlag
// custom resources from the GitOps platform, or a managed backend — call sites
// (Enabled below) are unchanged because they only touch the OpenFeature client.
//
// Lifecycle: short-lived *release* flags are removed after rollout (flag debt
// is the #1 failure mode); long-lived *ops/permission* flags are the exception.
// Delete this package and its example flag when you add your own first feature.
package featureflag

import (
	"context"
	"fmt"

	"github.com/open-feature/go-sdk/openfeature"
	"github.com/open-feature/go-sdk/openfeature/memprovider"
)

// ExampleFlag is a sample boolean flag key, evaluated default-off.
//
// It gates ExampleFeature below purely to demonstrate the both-states pattern;
// replace it with your own feature's key.
const ExampleFlag = "example-feature"

// NewProvider builds an OpenFeature provider that serves the given boolean flag
// states in-process — the template's default so the example evaluates and its
// tests pass with no running backend.
//
// In a real service, replace this with the flagd provider (or a managed
// backend); call sites are unaffected because they only touch the client.
func NewProvider(flags map[string]bool) *memprovider.InMemoryProvider {
	memFlags := make(map[string]memprovider.InMemoryFlag, len(flags))

	for key, on := range flags {
		variant := "off"
		if on {
			variant = "on"
		}

		memFlags[key] = memprovider.InMemoryFlag{
			Key:              "",
			State:            memprovider.Enabled,
			DefaultVariant:   variant,
			Variants:         map[string]any{"on": true, "off": false},
			ContextEvaluator: nil,
		}
	}

	return memprovider.NewInMemoryProvider(memFlags)
}

// NewClient registers provider under domain and returns a client bound to it.
//
// A real service calls this once at startup (domain = the service name); the
// returned client is safe to share across goroutines.
func NewClient(domain string, provider openfeature.FeatureProvider) (*openfeature.Client, error) {
	err := openfeature.SetNamedProviderAndWait(domain, provider)
	if err != nil {
		return nil, fmt.Errorf("register feature-flag provider for %q: %w", domain, err)
	}

	return openfeature.NewClient(domain), nil
}

// Enabled reports whether flag is on for client, defaulting to OFF on a missing
// flag or any evaluation error — the default-off rule every new feature follows
// so a flag failure can never silently turn a feature on.
func Enabled(ctx context.Context, client *openfeature.Client, flag string) bool {
	return client.Boolean(ctx, flag, false, openfeature.EvaluationContext{})
}

// ExampleFeature returns the feature's output when ExampleFlag is enabled and a
// safe default otherwise — the shape a real feature takes: guard the new path
// behind Enabled, keep the old path as the default. Delete this when you add
// your own first flagged feature.
func ExampleFeature(ctx context.Context, client *openfeature.Client) string {
	if Enabled(ctx, client, ExampleFlag) {
		return "new feature output"
	}

	return "default output"
}
