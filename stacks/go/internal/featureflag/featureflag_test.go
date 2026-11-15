package featureflag_test

import (
	"context"
	"testing"

	"github.com/devantler-tech/app/internal/featureflag"
)

func TestExampleFeature(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name  string
		flags map[string]bool
		want  string
	}{
		{
			name:  "flag on serves the new path",
			flags: map[string]bool{featureflag.ExampleFlag: true},
			want:  "new feature output",
		},
		{
			name:  "flag off serves the default path",
			flags: map[string]bool{featureflag.ExampleFlag: false},
			want:  "default output",
		},
		{
			name:  "flag absent defaults off",
			flags: map[string]bool{},
			want:  "default output",
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()

			provider := featureflag.NewProvider(testCase.flags)

			client, err := featureflag.NewClient(testCase.name, provider)
			if err != nil {
				t.Fatalf("NewClient(%q) returned error: %v", testCase.name, err)
			}

			got := featureflag.ExampleFeature(context.Background(), client)
			if got != testCase.want {
				t.Errorf("ExampleFeature() = %q, want %q", got, testCase.want)
			}
		})
	}
}
